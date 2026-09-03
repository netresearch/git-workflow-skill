#!/usr/bin/env python3
"""
PreToolUse hook to validate git commands for best practices.
Checks conventional commits, branch naming, and common mistakes.
"""

import json
import os
import re
import shlex
import subprocess
import sys
import tempfile
import time

# Enough of a body to count wrapped lines in; a cap so an accidentally huge
# file cannot stall the hook.
BODY_READ_LIMIT = 256 * 1024

# Conventional commit pattern
CONVENTIONAL_COMMIT_PATTERN = (
    r"^(feat|fix|docs|style|refactor|perf|test|build|ci|chore|revert)(\(.+\))?!?:\s.+"
)

# Git command patterns to check
CHECKS = [
    {
        "pattern": r'git\s+commit\s+.*-m\s*["\']([^"\']+)["\']',
        "check": "conventional_commit",
        "extract_group": 1,
    },
    {
        "pattern": r"git\s+checkout\s+-b\s+(\S+)",
        "check": "branch_name",
        "extract_group": 1,
    },
    {
        "pattern": r"git\s+push\s+(-f|--force)\s",
        "check": "force_push",
    },
    {
        "pattern": r"git\s+reset\s+--hard",
        "check": "hard_reset",
    },
    {
        "pattern": r"git\s+rebase\s+-i",
        "check": "interactive_rebase",
    },
    {
        "pattern": r"git\s+commit\s+--amend",
        "check": "amend_commit",
    },
]


# ---------------------------------------------------------------------------
# Gates. Unlike the advisory checks above these refuse the call, because each
# one describes an action that silently does the wrong thing rather than one
# that merely reads badly.
# ---------------------------------------------------------------------------

# Bodies posted to a forge: gh pr/issue/release create|edit|comment.
FORGE_BODY = re.compile(
    r"\bgh\s+(pr|issue|release)\s+(create|edit|comment|review)\b"
    r"|\bglab\s+(mr|issue|release)\s+(create|update|note|comment)\b"
    r"|/(?:pulls|issues)/[^\s'\"]*/(?:comments|replies)\b",
    re.IGNORECASE,
)
BODY_FILE = re.compile(r"--(?:body|notes)-file[= ]+(\S+)")
BODY_INLINE = re.compile(r"--(?:body|notes)[= ]+(['\"])(.*?)\1", re.DOTALL)
# `gh api … -f body=…` / `--field body=…` and `-F body=@file`: the review-reply
# endpoint takes its text this way, and a reply is the channel the PR-review
# rules mandate, so leaving it out would miss the case that motivated the gate.
BODY_FIELD = re.compile(
    r"(?:-f|--field|--raw-field)[= ]+body=(['\"])(.*?)\1", re.DOTALL
)
BODY_FIELD_FILE = re.compile(r"(?:-F|--field)[= ]+body=@(\S+)")

# Replying to a review comment needs the PR number in the path:
# repos/O/R/pulls/{pr}/comments/{id}/replies. Without it GitHub answers 404 and
# the reply is silently not posted. Two deliberate limits: only the /replies
# subresource is checked (`pulls/comments/{id}` is a legitimate read endpoint),
# and only a segment that actually invokes gh/curl counts — matching the path
# anywhere would block writing about it in an echo or a commit message.
REPLY_WITHOUT_PR = re.compile(r"/pulls/comments/[^/\s'\"]+/replies\b")
# The anchor matters: matching the path anywhere would block writing ABOUT it
# in an echo or a commit message. But anchoring on gh/curl alone let any
# prefix through -- `env FOO=1 gh api …` and `sudo gh api …` both slipped the
# gate -- so leading assignments and the usual wrapper words are skipped over
# first. Still anchored, so quoted prose stays unaffected.
INVOKES_FORGE_API = re.compile(
    r"^\s*(?:(?:[A-Za-z_][A-Za-z0-9_]*=\S*|sudo|env|time|command|nohup|xargs)\s+)*"
    r"(?:gh\s+api|curl)\b"
)

POLL_LOOP = re.compile(r"\b(?:until|while)\b.*?\bsleep\b", re.DOTALL)
FOR_LOOP_POLL = re.compile(r"\bfor\b[^\n]*\bin\b[^\n]*\bseq\b.*?\bsleep\b", re.DOTALL)
POLLS_PR = re.compile(
    r"\bgh\s+pr\s+(?:view|checks|status)\b"
    r"|\bgh\s+api\b[^\n]*?/pulls/"
    r"|\bpr-status\.sh\b"
)


def read_command(data) -> str:
    """Pull the command out of a PreToolUse payload.

    Claude Code sends {"tool_name": ..., "tool_input": {"command": ...}}. An
    earlier version read a top-level "command" key, which that payload does not
    have, so the hook returned silently on every invocation and none of the
    checks below ever ran.
    """
    if not isinstance(data, dict):
        return ""
    tool_input = data.get("tool_input")
    if isinstance(tool_input, dict) and tool_input.get("command"):
        return tool_input["command"]
    return data.get("command", "") or ""


def deny(reason: str) -> None:
    print(
        json.dumps(
            {
                "hookSpecificOutput": {
                    "hookEventName": "PreToolUse",
                    "permissionDecision": "deny",
                    "permissionDecisionReason": reason,
                }
            }
        )
    )


def hard_wrapped(text: str) -> int:
    """Count prose lines that look hard-wrapped at a fixed column.

    Only consecutive prose counts: a short line followed by more prose is the
    signature of a fixed-width wrap. Tables, lists, quotes, headings, link
    references and fenced code keep their own line structure and are skipped,
    as is a lone short line (a real one-line paragraph).
    """
    lines = text.split("\n")
    fenced = False
    hits = 0
    for i, ln in enumerate(lines):
        s = ln.strip()
        if s.startswith(("```", "~~~")):
            fenced = not fenced
            continue
        if fenced or not s:
            continue
        if re.match(r"^([-*+>#|]|\d+[.)]|\[)", s) or "|" in s:
            continue
        nxt = lines[i + 1].strip() if i + 1 < len(lines) else ""
        if not nxt or re.match(r"^([-*+>#|`]|\d+[.)]|\[)", nxt):
            continue
        # A prose line that stops in the 55-85 column band while the paragraph
        # continues on the next line was wrapped by hand, not by the renderer.
        if 55 <= len(ln.rstrip()) <= 85:
            hits += 1
    return hits


def _forge_bodies(cmd: str) -> list[tuple[str, str]]:
    """Every body this command would post, as (label, text)."""
    bodies: list[tuple[str, str]] = []
    for pattern in (BODY_FILE, BODY_FIELD_FILE):
        for m in pattern.finditer(cmd):
            p = m.group(1).strip("'\"")
            try:
                # Regular files only, and only the first chunk. `--body-file`
                # can name a pipe -- process substitution (`--body-file <(...)`)
                # hands over /dev/fd/N -- and reading one here blocks until a
                # writer this process cannot see appears. A hook that hangs is
                # worse than one that misses a finding, so a non-regular path is
                # skipped. `errors="replace"` because a body that is not valid
                # UTF-8 must not take the whole hook down with it: an exception
                # here would skip every other gate in this file.
                if not os.path.isfile(p):
                    continue
                with open(p, encoding="utf-8", errors="replace") as fh:
                    bodies.append((p, fh.read(BODY_READ_LIMIT)))
            except OSError:
                pass
    for m in BODY_INLINE.finditer(cmd):
        bodies.append(("--body", m.group(2)))
    for m in BODY_FIELD.finditer(cmd):
        bodies.append(("body=", m.group(2)))
    return bodies


def forge_body_hard_wrapped(cmd: str) -> str | None:
    if not FORGE_BODY.search(cmd):
        return None
    for name, text in _forge_bodies(cmd):
        n = hard_wrapped(text)
        if n >= 3:
            return (
                f"{name} carries {n} hard-wrapped prose lines. Bodies posted to "
                "GitHub/GitLab/Jira must NOT be wrapped at a fixed column: write "
                "each paragraph as ONE long line and let the renderer reflow it. "
                "Hard breaks read ragged in the web UI, break on mobile, and "
                "corrupt every later quote or diff — and in release notes they "
                "survive verbatim, unlike a CHANGELOG where markdown reflows. "
                "Tables, lists and fenced code keep their own line structure. "
                "(Commit messages are the exception and stay wrapped at ~72.)"
            )
    return None


# Function words that carry German prose and are not English words. "die",
# "man", "war", "so" and "in" are deliberately absent: they are English too,
# and a marker that fires on English is worse here than a missing one, because
# this gate denies rather than nudges.
# "mit" is absent although it is a German word: it is also the licence every
# skill repository names, 18 times in one 63k-word English corpus. A marker
# that fires on English prose is worse than a missing one, because this gate
# denies rather than nudges. Same reasoning excludes "das", "von" and "hat",
# which appear as DAS, von Neumann and HAT.
GERMAN_MARKERS = frozenset(
    [
        "und",
        "nicht",
        "wird",
        "werden",
        "wurde",
        "wurden",
        "eine",
        "einen",
        "einem",
        "einer",
        "der",
        "dem",
        "den",
        "des",
        "auch",
        "sich",
        "fuer",
        "für",
        "ueber",
        "über",
        "durch",
        "damit",
        "nach",
        "noch",
        "schon",
        "dann",
        "aber",
        "oder",
        "zum",
        "zur",
        "dass",
        "weil",
        "wenn",
        "ohne",
        "jetzt",
        "muss",
        "soll",
        "sind",
        "ist",
        "kann",
        "haben",
        "keine",
        "kein",
        "diese",
        "dieser",
        "dieses",
        "beim",
        "sowie",
        "bereits",
        "immer",
        "sehr",
        "zwei",
        "drei",
    ]
)
WORD = re.compile(r"[A-Za-zÄÖÜäöüß]+")
# An assignment in front of a command, not the string appearing anywhere: the
# name inside a quoted body must not switch the gate off for that same body.
GATE_OFF = re.compile(
    r"(?:^|[;&|]|\bthen\b|\bdo\b)\s*(?:[A-Za-z_][A-Za-z0-9_]*=\S*\s+)*"
    r"FORGE_LANGUAGE_GATE_OFF=1\s"
)
# Regions where German is quoted rather than written: fenced blocks, inline
# code, blockquotes and the argument of a quoted string. An English body may
# carry a German error log, a UI label or a fixture; measuring those as prose
# denies exactly the body that is doing the right thing.
QUOTED_REGIONS = (
    re.compile(r"```.*?```", re.DOTALL),
    re.compile(r"~~~.*?~~~", re.DOTALL),
    re.compile(r"`[^`]*`"),
    re.compile(r"^\s*>.*$", re.MULTILINE),
    re.compile(r"^\s{4,}\S.*$", re.MULTILINE),
    re.compile(r"[\"„»][^\"“«\n]{0,200}[\"“«]"),
)


def prose_only(text: str) -> str:
    for region in QUOTED_REGIONS:
        text = region.sub(" ", text)
    return text


def german_prose(text: str) -> tuple[int, float]:
    """(distinct markers, share of words that are markers) for a body."""
    words = [w.lower() for w in WORD.findall(prose_only(text))]
    if not words:
        return 0, 0.0
    hits = [w for w in words if w in GERMAN_MARKERS]
    return len(set(hits)), len(hits) / len(words)


def forge_body_not_english(cmd: str) -> str | None:
    """Deny a forge body written in the chat language rather than the repo's.

    The share matters as much as the count: an English body may quote a German
    fixture, a UI label or an error message, and that must not read as German
    prose. Both thresholds have to trip together.
    """
    # The escape hatch is read off the command, not the environment: the hook
    # runs as its own process, so a `VAR=1 gh …` prefix never reaches it as an
    # environment variable. Same convention as the attribution gate.
    if not FORGE_BODY.search(cmd) or GATE_OFF.search(cmd):
        return None
    for name, text in _forge_bodies(cmd):
        distinct, share = german_prose(text)
        if distinct >= 6 and share >= 0.08:
            return (
                f"{name} looks like German prose ({distinct} distinct German "
                f"function words, {share:.0%} of all words). Everything on the "
                "forge is English: PR and issue bodies, review comments, "
                "release notes and labels are read by whoever finds the "
                "repository, not only by the person the chat is with. Write it "
                "in English — the conversation language does not travel with "
                "the artifact. Quoting a German string (a fixture, a UI label, "
                "an error message) inside an English body is fine and does not "
                "trip this. Prefix the command with FORGE_LANGUAGE_GATE_OFF=1 "
                "for a repository whose own language is German."
            )
    return None


def reply_path_without_pr(cmd: str) -> str | None:
    for segment in re.split(r"(?:\|\||&&|[;|&\n])", cmd):
        if INVOKES_FORGE_API.match(segment) and REPLY_WITHOUT_PR.search(segment):
            return (
                "A review-comment reply needs the PR number in the path — this "
                "one would 404 and post nothing:\n\n"
                "  repos/{owner}/{repo}/pulls/{pr}/comments/{comment_id}/replies\n\n"
                "`repos/{owner}/{repo}/pulls/comments/{comment_id}` (without "
                "/replies) is the valid form for READING one comment, which is "
                "where the shorter path comes from."
            )
    return None


# The plugin's scripts are not on PATH: recommending a bare `pr-status.sh`
# sends the reader into `command not found` (exit 127) and a hunt through the
# plugin cache before the gate's advice becomes followable (2026-08-13). The
# script ships in this plugin, so the message can name the invocable path;
# the bare name stays as fallback for layouts where the sibling is absent.
_PR_STATUS_SH = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "skills",
    "git-workflow",
    "scripts",
    "pr-status.sh",
)
PR_STATUS = _PR_STATUS_SH if os.path.isfile(_PR_STATUS_SH) else "pr-status.sh"


def handrolled_pr_poll(cmd: str) -> str | None:
    if "--watch" in cmd or not POLLS_PR.search(cmd):
        return None
    if not (POLL_LOOP.search(cmd) or FOR_LOOP_POLL.search(cmd)):
        return None
    return (
        "Hand-rolled poll over pull-request state. Use "
        f"`{PR_STATUS} -R <owner/repo> <pr> --watch` instead: it returns at the "
        "FIRST actionable event — a check that failed, a review that arrived, a "
        "thread that needs an answer — where a loop written here waits for the "
        "one outcome it was told about and sleeps through the rest. A loop that "
        "exited only on `merge` slept through the review it was waiting for, and "
        "the operator had to ask what was happening."
    )


# Asking GitHub directly whether a pull request can merge is the poll above
# without the loop: `gh pr view --json mergeStateStatus` and
# `gh api .../pulls/N --jq .mergeable_state` answer "blocked" and never say
# why, staying blind to the two states that usually cause it — an unresolved
# review thread and a failing check. pr-status.sh reports both and ends with a
# NEXT: line naming the action.
#
# Only a segment that actually INVOKES gh counts. Matching the words anywhere
# would block writing ABOUT the rule: a heredoc carrying test cases, an echo,
# a grep pattern, this rule's own tests.
MERGE_READINESS_FIELD = re.compile(
    r"\bmergeable_state\b|\bmergeStateStatus\b|\bmergeable\b|\breviewDecision\b"
)
# A loop body arrives as " do gh api ..." once the command is split on
# separators, so the shell keywords that can precede the call are skipped.
QUERIES_FORGE = re.compile(r"\s*(?:(?:do|then|else|\{)\s+)*gh\s+(?:pr\s+view|api)\b")


def merge_readiness_without_pr_status(cmd: str) -> str | None:
    # A command that already runs pr-status.sh is the recommended shape, and
    # `isRequired` is the GraphQL query naming WHICH required context is unmet
    # — a deliberate deep dive pr-status.sh does not break down.
    if "pr-status.sh" in cmd or "isRequired" in cmd:
        return None

    for segment in re.split(r"(?:\|\||&&|[;|&\n])", cmd):
        if QUERIES_FORGE.match(segment) and MERGE_READINESS_FIELD.search(segment):
            return (
                "Merge readiness asked of gh directly. Use "
                f"`{PR_STATUS} -R <owner/repo> <pr>` instead: it reports checks, "
                "reviews, rulesets and unresolved threads together and ends with "
                "a NEXT: line naming the action. mergeable_state and "
                "mergeStateStatus answer only 'blocked' and never say why, so an "
                "unresolved thread or a red check stays invisible and the pull "
                "request looks like it is merely waiting. To find out which "
                f"required context is unmet, run {PR_STATUS} first, then the "
                "GraphQL query with `isRequired` — that one is not gated."
            )
    return None


# ---------------------------------------------------------------------------
# Gates promoted from a harness-local hook (2026-08-15). Each earned its place
# by a real incident; the comment above each names it.
# ---------------------------------------------------------------------------

# A commit hash written from memory instead of looked up. A reader who follows
# a wrong hash finds nothing, and the claim it supported becomes unverifiable
# (2026-08-03: a review reply cited 8e1c9b0 for work that landed in 4a4e981).
# Hex, 7-40 chars, at least one letter so a PR number does not qualify, and no
# `-`/`/` on either side so hex runs inside a UUID path are not mistaken for
# hashes.
SHA_TOKEN = re.compile(
    r"(?<![0-9a-zA-Z/_.-])(?=[0-9a-f]*[a-f])[0-9a-f]{7,40}(?![0-9a-zA-Z/_.-])"
)
POSTS_TEXT = re.compile(
    r"\bgh\s+(?:pr|issue)\s+(?:comment|create|edit)\b"
    r"|\bgh\s+api\b[^\n]*?/(?:comments|replies|issues)\b"
    r"|\bglab\s+(?:mr|issue)\s+(?:note|create|update)\b"
)
TARGET_REPO = re.compile(r"--repo[= ]([\w.-]+/[\w.-]+)|\brepos/([\w.-]+/[\w.-]+)/")

# A quoted heredoc body is literal data — a file being written, a test fixture,
# a payload. Scanning it flags documentation that merely CONTAINS a forge call
# with an example hash; the harness-local ancestor of this gate blocked exactly
# that while its own test cases were being written. Unquoted heredocs expand
# and stay in.
QUOTED_HEREDOC = re.compile(r"<<-?\s*(['\"])(\w+)\1.*?^\2$", re.DOTALL | re.MULTILINE)


def _resolve_commit(repo: str, token: str):
    """True/False when the forge answered, None when it could not be asked."""
    try:
        p = subprocess.run(
            ["gh", "api", f"repos/{repo}/commits/{token}", "--jq", ".sha"],
            capture_output=True,
            timeout=8,
            check=False,
            text=True,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if p.returncode == 0:
        return True
    err = p.stderr or ""
    # 422 "No commit found for SHA" / 404 unknown ref are answers; anything
    # else (auth, rate limit, network) is "could not check", not "invented".
    if "No commit found" in err or "HTTP 404" in err:
        return False
    return None


def unresolvable_sha(cmd: str, resolve=_resolve_commit) -> str | None:
    """Deny a published body naming a commit the target repo does not know."""
    cmd = QUOTED_HEREDOC.sub(" ", cmd or "")
    if not POSTS_TEXT.search(cmd):
        return None
    m = TARGET_REPO.search(cmd)
    if not m:
        return None
    repo = m.group(1) or m.group(2)
    urls = re.findall(r"https?://\S+", cmd)
    bad = [
        t
        for t in sorted(set(SHA_TOKEN.findall(cmd)))
        if not any(t in u for u in urls) and resolve(repo, t) is False
    ]
    if not bad:
        return None
    return (
        "This body names commit " + ", ".join(bad) + ", which resolves to no "
        "object in this repository — a hash written from memory rather than "
        "looked up. Get the real one (`git rev-parse --short HEAD`, "
        "`git log -1 --format=%h`) and put that in the text; a reader who "
        "follows a wrong hash finds nothing and the claim it supported becomes "
        "unverifiable."
    )


# Waiting on workflow runs is legitimate — after a merge there is no PR to
# watch — but two defects recur in hand-written loops and both are cheap to
# catch: waiting for EVERY run (the first failure is actionable minutes
# earlier) and having no arm for the query itself failing (one such loop spun
# 20 rounds against an exhausted quota, reporting nothing).
POLLS_RUNS = re.compile(r"\bgh\s+run\s+(?:list|view|watch)\b")
WAITS_FOR_ALL_RUNS = re.compile(
    r'status\s*!=\s*"?completed'
    r"|!=\s*'completed'"
    r"|\bpending\b[^\n]{0,20}(?:==|-eq)\s*0"
)
HAS_FAILURE_ARM = re.compile(
    r"\|\|\s*echo\s+\w+.*?\b(?:break|exit)\b"
    r"|\berr\w*\s*\)"
    r'|""\s*\|'
    r"|\brate_limit\b",
    re.DOTALL,
)


def run_poll_problem(cmd: str) -> str | None:
    """Warn (never deny) about a run-poll that cannot report a failure early."""
    if not POLLS_RUNS.search(cmd):
        return None
    if not (POLL_LOOP.search(cmd) or FOR_LOOP_POLL.search(cmd)):
        return None
    reasons = []
    if WAITS_FOR_ALL_RUNS.search(cmd):
        reasons.append(
            "  - It exits only when every run has finished. The first failing "
            "job is actionable at once, but gets slept through until the "
            "slowest matrix cell ends."
        )
    if not HAS_FAILURE_ARM.search(cmd):
        reasons.append(
            "  - It has no branch for the query itself failing. An empty answer "
            "(rate limit, wrong flag, output on stderr) reads as 'not ready "
            "yet', and the loop spins silently."
        )
    if not reasons:
        return None
    return (
        "Waiting on workflow runs is fine — after a merge there is no PR to "
        "watch. Two defects in this loop:\n\n"
        + "\n".join(reasons)
        + "\n\nExit on the first failing run, not only on completion. Write the "
        'failure arm before the success arms: `case "$x" in "" | err) echo '
        '"query failed"; break ;; …`. And when the round limit runs out, print '
        "that — an abandoned wait is not an observation."
    )


# A git measurement inherits its working directory: `cd` survives between tool
# calls, so a command issued later still runs wherever the last one left off.
# The failure mode is not an error — it succeeds and answers about a different
# repository (2026-08-12: an `ls-remote` answered from the wrong checkout and
# produced a wrong "deviation" claim). Reads only; writes are covered by the
# reference-worktree gate.
#
# One separator class for both halves. They must agree: whatever counts as a
# statement boundary before `git` has to count as one before `cd`, or a command
# that names its directory still draws the advisory. They did not agree —
# `(` and `$(` opened a measurement but not a cd — so `(cd /etc && git status)`
# and `x=$(cd /srv && git rev-parse HEAD)` were reported as unnamed.
_SEP = r"(?:^|[|&;\n(]|\$\()"
GIT_MEASURING_READ = re.compile(
    _SEP + r"\s*git\s+(?!-C\b)(?!--git-dir)(?:-c\s+\S+\s+)*"
    r"(ls-remote|rev-parse|rev-list|log|status|diff|show|describe"
    r"|symbolic-ref|for-each-ref|ls-files|cat-file)\b"
)
# The operand has to be a directory. `cd &&` has none; `cd -` returns to
# $OLDPWD, which changes the directory but names none a reader can see. `--`
# is an option terminator and the directory follows it, so it stays allowed.
CD_BEFORE = re.compile(_SEP + r"\s*cd\s+(?:--\s+\S|(?![-&|;])\S)")
# A quote is not a statement separator, so `ssh host 'cd /etc && git log -1'`
# read as "no cd" and drew the advisory on every remote inspection.
_QUOTES = "\"'"


def _same_scope_prefix(cmd: str, end: int) -> str:
    """`cmd[:end]` with everything outside the measurement's own scope blanked.

    A `cd` only reaches a later command when it ran in the same shell. Two ways
    it does not, and both were accepted before:

    * `(cd /etc && ls); git status` — the subshell exited, taking its `cd` with
      it, so the local `git status` is exactly the unnamed measurement the
      advisory is for.
    * `ssh host "echo ok; cd /etc && ls"; git status` — the `cd` ran on another
      machine.

    Closed quoted runs and closed `(...)` groups are therefore blanked out.
    Whatever is still open at `end` is the scope the measurement sits in, so
    the text before it is blanked instead — that makes the run's own start the
    `^` the pattern needs, since a quote is not a separator.
    """
    out = list(cmd[:end])
    quote, quote_start, opens = "", -1, []
    for i, ch in enumerate(cmd[:end]):
        if quote:
            if ch == quote:
                out[quote_start : i + 1] = " " * (i - quote_start + 1)
                quote = ""
            continue
        if ch in _QUOTES:
            quote, quote_start = ch, i
        elif ch == "(":
            opens.append(i)
        elif ch == ")" and opens:
            start = opens.pop()
            out[start : i + 1] = " " * (i - start + 1)
    innermost = max(quote_start if quote else -1, opens[-1] if opens else -1)
    if innermost >= 0:
        out[: innermost + 1] = " " * (innermost + 1)
    return "".join(out)


def _named_directory_before(cmd: str, end: int) -> bool:
    """True when a `cd` names the directory the measurement at `end` runs in."""
    return bool(CD_BEFORE.search(_same_scope_prefix(cmd, end)))


# The escape hatch shared by the state-changing gates. It counts only at the
# start of a command, where a shell would read it as an environment
# assignment; anywhere else it is text. A substring test let
# `git commit -m 'document DESTRUCTIVE_GIT_GATE_OFF=1'` through both gates,
# and this repository's own commit messages name the marker (2026-09-03).
_STATEMENT_BREAK = re.compile(r"[;&|\n]|\$\(|\(")
_ASSIGNMENT = r"[A-Za-z_][A-Za-z0-9_]*=\S*\s+"
_GATE_OFF_PREFIX = re.compile(
    rf"\s*(?:{_ASSIGNMENT})*DESTRUCTIVE_GIT_GATE_OFF=1\s*(?:{_ASSIGNMENT})*"
)


def _statement_start(cmd: str, end: int) -> int:
    """Index just past the separator that opens the statement holding `end`."""
    breaks = [m.end() for m in _STATEMENT_BREAK.finditer(cmd[:end])]
    return breaks[-1] if breaks else 0


def _gate_disabled(cmd: str, end: int) -> bool:
    """True when the escape-hatch assignment prefixes the statement at `end`.

    Scoped to the statement rather than the whole payload: as a whole-command
    test, `DESTRUCTIVE_GIT_GATE_OFF=1 true; git push origin main` disabled the
    gate for a write the assignment never prefixed (2026-09-03 review).
    """
    return bool(_GATE_OFF_PREFIX.fullmatch(cmd[_statement_start(cmd, end) : end]))


# --- blanket `git add` (promoted from a harness-local hook, 2026-08-20) ------
# `git add -A` / `git add .` / `--all` stages every untracked, non-ignored file
# in the tree. Named paths are the rule (CLAUDE.md, Git / PR / release); the
# rule was written down and still violated: a var/ DI-container cache — 40k
# lines across four files — rode into a commit and had to be amended and
# force-pushed out again. The gate is state-aware and narrow: it looks at the
# repository the command names (or the payload's cwd), and denies only when
# untracked, non-ignored files exist — a clean tree and a named path pass.

_GIT_ADD = re.compile(
    r"(?:^|[\s;&|(])git\s+(?:-C\s+(?P<dir>\S+)\s+)?(?:-\S+\s+)*add\b(?P<rest>[^;&|\n]*)"
)
_WHOLE_TREE = {".", "./", ":/", "*", "'*'", '"*"', ":(top)"}


def _untracked_files(repo_dir: str) -> list[str] | None:
    """Untracked, non-ignored paths, or None when git could not be asked."""
    try:
        p = subprocess.run(
            ["git", "-C", repo_dir, "status", "--porcelain", "--untracked-files=all"],
            capture_output=True,
            text=True,
            timeout=8,
            check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if p.returncode != 0:
        return None
    return [line[3:] for line in p.stdout.splitlines() if line.startswith("?? ")]


def blanket_git_add(cmd: str, cwd: str = "", untracked=_untracked_files) -> str | None:
    """Deny `git add -A|--all|.` while untracked, non-ignored files exist."""
    cmd = QUOTED_HEREDOC.sub(" ", cmd or "")
    for m in _GIT_ADD.finditer(cmd):
        if _gate_disabled(cmd, m.start()):
            continue
        rest = m.group("rest")
        try:
            tokens = shlex.split(rest)
        except ValueError:
            tokens = rest.split()
        options = [t for t in tokens if t.startswith("-")]
        operands = [t for t in tokens if not t.startswith("-")]
        blanket = any(
            o in {"-A", "--all", "--no-ignore-removal"} for o in options
        ) or any(o in _WHOLE_TREE for o in operands)
        if not blanket:
            continue
        repo_dir = m.group("dir") or cwd or os.getcwd()
        if not os.path.isdir(repo_dir):
            continue
        strays = untracked(repo_dir)
        if not strays:
            continue
        shown = "\n".join(f"  {line}" for line in strays[:12])
        if len(strays) > 12:
            shown += f"\n  … and {len(strays) - 12} more"
        return (
            "This would stage every untracked file in the tree, not only your change:\n\n"
            f"  {m.group(0).strip()}\n\n"
            f"Untracked, non-ignored files it would sweep in:\n\n{shown}\n\n"
            "Name the paths you changed (`git add <file> <file>`), or ignore/remove the "
            "strays first. A blanket add once carried 40k lines of DI-container cache into "
            "a commit that then had to be amended and force-pushed (2026-08-20). If sweeping "
            "them in really is the point, prefix the command with DESTRUCTIVE_GIT_GATE_OFF=1."
        )
    return None


def git_read_without_named_dir(cmd: str) -> str | None:
    """Warn when a git measurement does not say which directory it measures."""
    cmd = cmd or ""
    # Every measurement, not just the first: `ssh host 'cd /etc && git status';
    # git status` opens with a remote measurement that names its directory, and
    # stopping there suppressed the local one that does not — the only line in
    # that command the advisory is actually about.
    if not any(
        not _named_directory_before(cmd, m.start())
        for m in GIT_MEASURING_READ.finditer(cmd)
    ):
        return None
    return (
        "This git command inherits its working directory. `cd` survives between "
        "tool calls, so it runs wherever the last one left off — and on the "
        "wrong repository it does not fail, it answers about that one. If this "
        "output becomes a claim, name the directory:\n\n"
        "  git -C /abs/path <subcommand>\n"
        "  cd /abs/path && git <subcommand>\n\n"
        "Nothing to change if you only need the current checkout."
    )


# --- git writes that do not name their directory (2026-09-03) ---------------
# The read advisory above tells the author once per session; a write cannot
# afford a warning it may not read. `cd` survives between tool calls, so a
# `git push` that omits its directory runs wherever the previous call stopped
# — on 2026-09-03 in a simulator checkout instead of the addon worktree, and
# only a branch that did not exist there kept it from pushing. A write in the
# wrong repository does not fail; it succeeds there. The rule ("every call
# names its directory") had been written down for weeks and still lapsed
# under a long chain of commands, which is the case for a gate.
GIT_WRITE_SUBCOMMANDS = frozenset(
    {
        "commit",
        "push",
        "pull",
        "merge",
        "rebase",
        "cherry-pick",
        "revert",
        "reset",
        "checkout",
        "switch",
        "restore",
        "stash",
        "tag",
        "branch",
        "worktree",
        "am",
        "apply",
        "rm",
        "mv",
    }
)
# Global options are skipped rather than enumerated: a pattern that knew only
# `-c` missed the write in `git --no-pager push origin main`. These take a
# separate value, so the value is not mistaken for the subcommand.
_GIT_OPTIONS_WITH_VALUE = frozenset(
    {
        "-C",
        "-c",
        "--git-dir",
        "--work-tree",
        "--namespace",
        "--exec-path",
        "--config-env",
    }
)
# `git` as its own token, so `env X=1 git push` is seen. A separator is not
# required, unlike the read advisory's pattern.
_GIT_TOKEN = re.compile(r"(?:^|(?<=[\s|&;\n('\"`]))git(?=\s)")
# A shell takes no escapes inside single quotes and takes them inside
# double ones. One spelling, so the payload pattern below cannot drift
# from it — it did, and hid a write behind an earlier escaped quote.
# ANSI-C quoting comes first: at the `$` the scan must take the whole
# `$'…'`, not the `'…'` one character later. Its backslash escapes are
# interpreted, so it reads like the double-quoted form.
_QUOTED = r"\$'(?:[^'\\]|\\.)*'|'[^']*'|\"(?:[^\"\\]|\\.)*\""
_QUOTED_RUN = re.compile(_QUOTED)


# A payload a local shell runs, as opposed to a quoted argument. `ssh host
# '…'` is deliberately absent: it runs on another machine, whose working
# directory is not the one this gate is about.
_LOCAL_SHELL_PAYLOAD = re.compile(
    r"(?:^|[\s|&;(`])(?:ba|z|da|k)?sh\s+(?:[^'\"]*?\s)?-[A-Za-z]*c\s+"
    rf"(?P<payload>{_QUOTED})"
)


def _without_quoted_runs(cmd: str) -> str:
    """`cmd` with quoted runs blanked to spaces, positions preserved.

    A `git push` inside quotes is usually text — a commit message naming the
    command — so `git -C /r commit -m "fix git push"` must not read as a
    second, unnamed write. A payload a local shell will run is the exception
    and stays visible, so `bash -c 'git push'` is seen as the write it is.
    """
    masked = list(_QUOTED_RUN.sub(lambda m: " " * len(m.group(0)), cmd))
    for match in _LOCAL_SHELL_PAYLOAD.finditer(cmd):
        start, end = match.span("payload")
        masked[start:end] = cmd[start:end]
    return "".join(masked)


def _names_a_directory(option: str, operand: str) -> bool:
    """True when the option carries a directory git will actually change to.

    `git -C "" push` changes nothing — git reads an empty operand as no
    directory at all (git 2.55.0) — so it must not count as named.
    """
    if option in ("-C", "--git-dir"):
        return bool(operand.strip("\"'").strip())
    if option.startswith(("-C=", "--git-dir=")):
        return bool(option.split("=", 1)[1].strip("\"'").strip())
    return False


def _git_invocations(cmd: str):
    """Yield `(subcommand, start, names_directory)` for each `git` call."""
    scanned = _without_quoted_runs(cmd)
    for match in _GIT_TOKEN.finditer(scanned):
        # Found in the scanned text so quoted argument text is not read as a
        # command; parsed from the original so an operand blanked with its
        # quotes (`-C ""`) is still there to be judged.
        rest = re.split(r"[;\n|&]", cmd[match.end() :], maxsplit=1)[0]
        # Shell rules, not whitespace: `git "push" origin main` kept its quotes
        # and `git -c "user.name=A B" push` split the value, so in both the
        # subcommand read as something that is not a write (2026-09-03 review).
        # Splitting `rest` at a separator can leave a quote unbalanced, which is
        # what the fallback is for.
        try:
            tokens = shlex.split(rest)
        except ValueError:
            tokens = rest.split()
        names_directory = False
        index = 0
        while index < len(tokens) and tokens[index].startswith("-"):
            option = tokens[index]
            takes_value = option in _GIT_OPTIONS_WITH_VALUE
            operand = (
                tokens[index + 1] if takes_value and index + 1 < len(tokens) else ""
            )
            if _names_a_directory(option, operand):
                names_directory = True
            index += 2 if takes_value else 1
        subcommand = tokens[index] if index < len(tokens) else ""
        yield subcommand, match.start(), names_directory


def git_write_without_named_dir(cmd: str) -> str | None:
    """Deny a git write that neither uses `-C` nor follows a `cd` in its scope."""
    cmd = cmd or ""
    unnamed = [
        subcommand
        for subcommand, start, names_directory in _git_invocations(cmd)
        if subcommand in GIT_WRITE_SUBCOMMANDS
        and not names_directory
        and not _named_directory_before(cmd, start)
        and not _gate_disabled(cmd, start)
    ]
    if not unnamed:
        return None
    return (
        f"`git {unnamed[0]}` changes state without naming its directory. `cd` "
        "survives between tool calls, so this runs wherever the last call left "
        "off — and in the wrong repository it does not fail, it succeeds there "
        "(2026-09-03: a `git push` ran in a simulator checkout instead of the "
        "addon worktree; only a branch that did not exist there stopped it). "
        "Name the directory:\n\n"
        "  git -C /abs/path <subcommand>\n"
        "  cd /abs/path && git <subcommand>\n\n"
        "Reads keep their once-per-session advisory. If running in the "
        "inherited directory really is the point, prefix the command with "
        "DESTRUCTIVE_GIT_GATE_OFF=1."
    )


def check_conventional_commit(message: str) -> str | None:
    """Validate commit message follows conventional commits."""
    if not re.match(CONVENTIONAL_COMMIT_PATTERN, message):
        return f"""Commit message doesn't follow Conventional Commits format.

Expected: <type>(<scope>): <description>
Types: feat, fix, docs, style, refactor, perf, test, build, ci, chore, revert

Examples:
  feat: add user authentication
  fix(api): handle null response
  docs: update README installation section

Your message: "{message[:50]}..." """
    return None


def check_branch_name(name: str) -> str | None:
    """Validate branch name follows conventions."""
    valid_patterns = [
        r"^(feature|feat|fix|bugfix|hotfix|release|chore|docs)/[\w-]+$",
        r"^(main|master|develop|staging)$",
    ]
    if not any(re.match(p, name) for p in valid_patterns):
        return f"""Branch name '{name}' doesn't follow conventions.

Recommended patterns:
  feature/description-here
  fix/issue-description
  hotfix/critical-fix
  release/v1.2.3"""
    return None


def check_command(command: str) -> list[dict]:
    """Check git command for best practices."""
    warnings = []

    for check in CHECKS:
        match = re.search(check["pattern"], command, re.IGNORECASE)
        if not match:
            continue

        check_type = check["check"]

        if check_type == "conventional_commit":
            msg = match.group(check.get("extract_group", 0))
            warning = check_conventional_commit(msg)
            if warning:
                warnings.append({"severity": "info", "message": warning})

        elif check_type == "branch_name":
            name = match.group(check.get("extract_group", 0))
            warning = check_branch_name(name)
            if warning:
                warnings.append({"severity": "info", "message": warning})

        elif check_type == "force_push":
            warnings.append(
                {
                    "severity": "warning",
                    "message": "Force push can overwrite remote history. Ensure this is intentional.",
                }
            )

        elif check_type == "hard_reset":
            warnings.append(
                {
                    "severity": "warning",
                    "message": "Hard reset discards uncommitted changes permanently.",
                }
            )

        elif check_type == "interactive_rebase":
            warnings.append(
                {
                    "severity": "info",
                    "message": "Interactive rebase requires manual input - not supported in this environment.",
                }
            )

        elif check_type == "amend_commit":
            warnings.append(
                {
                    "severity": "info",
                    "message": "Amending commits rewrites history. Avoid on pushed commits.",
                }
            )

    return warnings


# A session can run for days and its context gets compacted along the way, so
# an advisory seen once at the start is long gone by the time the same slip
# recurs. An old enough marker re-arms the advisory: one fresh warning, then
# quiet again for another window.
ADVISORY_REARM_SECONDS = 6 * 60 * 60


def _advisory_already_fired(data, name: str) -> bool:
    """True if this advisory has already fired recently in this session.

    Both advisories restate a general rule rather than reporting a fact about
    the particular command in hand. Repeating one on every matching call is
    noise: the first has already told the author what to check, and the message
    reaches the user's transcript via systemMessage, so the cost is paid in
    their attention rather than ours. Fire once per session per advisory, and
    once more per ADVISORY_REARM_SECONDS window in a long-running session.

    Every storage failure returns False: a marker problem must never suppress
    a warning. The marker directory is therefore created in its own try block
    — if XDG_RUNTIME_DIR names something unusable, makedirs raises before any
    marker could exist, and that has to read as "not fired", not as
    FileExistsError at the marker call.

    XDG_RUNTIME_DIR is only trusted once it has been shown to work. Login
    shells export it whether or not the directory exists, and where there is no
    systemd user session (WSL, containers, a cron-launched session) it names a
    path under root-owned /run/user that cannot be created. Treating that as
    "not fired" is permanent: the advisory then repeats on every matching
    command for the life of the session, which is the storm the once-per-
    session rule exists to prevent. So fall back to the temp directory, and
    keep returning False only when nowhere at all can hold a marker.
    """
    session_id = data.get("session_id") if isinstance(data, dict) else None
    if not session_id:
        return False
    slug = re.sub(r"[^A-Za-z0-9_-]", "", str(session_id))
    if not slug:
        return False
    # A root is only usable once the MARKER itself can be written. makedirs
    # succeeding proves nothing: the advisory directory can already exist and be
    # unwritable, and committing to that root then leaves the dedupe off for the
    # rest of the session — the storm this whole mechanism exists to prevent.
    # So each root is tried all the way through, and only a write failure on the
    # last one reads as "not fired".
    for root in (os.environ.get("XDG_RUNTIME_DIR"), tempfile.gettempdir()):
        if not root:
            continue
        directory = os.path.join(root, "git-workflow-advisories")
        try:
            os.makedirs(directory, exist_ok=True)
        except OSError:
            continue
        marker = os.path.join(directory, f"{slug}.{name}")
        try:
            os.close(os.open(marker, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600))
        except FileExistsError:
            try:
                # A marker mtime in the future (backwards clock step) makes the
                # delta negative and reads as fresh: stay quiet rather than storm.
                if time.time() - os.stat(marker).st_mtime > ADVISORY_REARM_SECONDS:
                    os.utime(marker, None)
                    return False
            except OSError:
                return False
            return True
        except OSError:
            continue  # this root cannot hold markers — try the next
        return False
    return False


def main():
    try:
        input_data = sys.stdin.read()
    except Exception:  # noqa: BLE001 - git hook entry point: any stdin read failure is a no-op
        return

    if not input_data:
        return

    try:
        data = json.loads(input_data)
        command = read_command(data)
    except (json.JSONDecodeError, TypeError):
        data = {}
        command = input_data

    if not command:
        return

    # Gates that refuse the call outright. Checked before the advisory
    # warnings because a denied command never runs, so warning about its
    # style would be noise.
    gates = [
        forge_body_hard_wrapped,
        forge_body_not_english,
        reply_path_without_pr,
        handrolled_pr_poll,
        merge_readiness_without_pr_status,
        unresolvable_sha,
    ]
    for gate in gates:
        reason = gate(command)
        if reason:
            deny(reason)
            return
    # State-aware gate: needs the repository the command runs in.
    cwd = data.get("cwd", "") if isinstance(data, dict) else ""
    reason = blanket_git_add(command, cwd if isinstance(cwd, str) else "")
    if reason:
        deny(reason)
        return
    # After the specific gates: a blanket add or a conflict marker names the
    # sharper reason, and only then does the unnamed directory get its turn.
    reason = git_write_without_named_dir(command)
    if reason:
        deny(reason)
        return

    # Advisory: the command is usually right, and only its author knows whether
    # the inherited directory or the poll shape was intended.
    for advisory in (run_poll_problem, git_read_without_named_dir):
        note = advisory(command)
        if note:
            if _advisory_already_fired(data, advisory.__name__):
                # This advisory is spent, but the other one may still owe the
                # session its first warning — keep looking instead of exiting.
                continue
            print(
                json.dumps(
                    {"systemMessage": f"git-workflow: {note}", "suppressOutput": True}
                )
            )
            # One message per call: mixing this JSON line with check_command's
            # plain-text reminder on the same stdout would be ambiguous to the
            # harness. Only a SPENT advisory falls through (continue above), so
            # a suppressed advisory no longer swallows unrelated warnings.
            return

    if "git" not in command.lower():
        return

    warnings = check_command(command)

    if warnings:
        severity_icons = {"warning": "⚠️", "info": "ℹ️", "error": "❌"}
        output_lines = []
        for w in warnings:
            icon = severity_icons.get(w["severity"], "•")
            output_lines.append(f"{icon} {w['message']}")

        print(f"""<system-reminder>
Git workflow check:
{chr(10).join(output_lines)}

See git-workflow skill for best practices.
</system-reminder>""")


if __name__ == "__main__":
    main()
