#!/usr/bin/env python3
"""
PreToolUse hook to validate git commands for best practices.
Checks conventional commits, branch naming, and common mistakes.
"""

import json
import os
import re
import subprocess
import sys

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
    r"\bgh\s+(pr|issue|release)\s+(create|edit|comment)\b", re.IGNORECASE
)
BODY_FILE = re.compile(r"--(?:body|notes)-file[= ]+(\S+)")
BODY_INLINE = re.compile(r"--(?:body|notes)[= ]+(['\"])(.*?)\1", re.DOTALL)

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
    for m in BODY_FILE.finditer(cmd):
        p = m.group(1).strip("'\"")
        try:
            # Regular files only, and only the first chunk. `--body-file` can
            # name a pipe -- process substitution (`--body-file <(...)`) hands
            # over /dev/fd/N -- and reading one here blocks until a writer this
            # process cannot see appears. A hook that hangs is worse than one
            # that misses a finding, so a non-regular path is skipped.
            if not os.path.isfile(p):
                continue
            with open(p, encoding="utf-8") as fh:
                bodies.append((p, fh.read(BODY_READ_LIMIT)))
        except OSError:
            pass
    for m in BODY_INLINE.finditer(cmd):
        bodies.append(("--body", m.group(2)))
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
GERMAN_MARKERS = frozenset(
    """und nicht wird werden wurde wurden eine einen einem einer der dem den des
    das auch sich fuer für ueber über durch damit nach noch schon dann aber oder
    mit von zum zur dass weil wenn ohne jetzt muss soll sind ist kann haben hat
    keine kein diese dieser dieses beim sowie bereits immer sehr zwei drei""".split()
)
WORD = re.compile(r"[A-Za-zÄÖÜäöüß]+")


def german_prose(text: str) -> tuple[int, int]:
    """(distinct markers, share of words that are markers) for a body."""
    words = [w.lower() for w in WORD.findall(text)]
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
    if not FORGE_BODY.search(cmd):
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
                "trip this. Set FORGE_LANGUAGE_GATE_OFF=1 for a repository "
                "whose own language is German."
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
GIT_MEASURING_READ = re.compile(
    r"(?:^|[|&;\n(]|\$\()\s*git\s+(?!-C\b)(?!--git-dir)(?:-c\s+\S+\s+)*"
    r"(ls-remote|rev-parse|rev-list|log|status|diff|show|describe"
    r"|symbolic-ref|for-each-ref|ls-files|cat-file)\b"
)
CD_BEFORE = re.compile(r"(?:^|[|&;\n])\s*cd\s+\S")


def git_read_without_named_dir(cmd: str) -> str | None:
    """Warn when a git measurement does not say which directory it measures."""
    m = GIT_MEASURING_READ.search(cmd or "")
    if not m or CD_BEFORE.search(cmd[: m.start()]):
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
        command = input_data

    if not command:
        return

    # Gates that refuse the call outright. Checked before the advisory
    # warnings because a denied command never runs, so warning about its
    # style would be noise.
    gates = [
        forge_body_hard_wrapped,
        reply_path_without_pr,
        handrolled_pr_poll,
        merge_readiness_without_pr_status,
        unresolvable_sha,
    ]
    if not os.environ.get("FORGE_LANGUAGE_GATE_OFF"):
        gates.insert(1, forge_body_not_english)
    for gate in gates:
        reason = gate(command)
        if reason:
            deny(reason)
            return

    # Advisory: the command is usually right, and only its author knows whether
    # the inherited directory or the poll shape was intended.
    for advisory in (run_poll_problem, git_read_without_named_dir):
        note = advisory(command)
        if note:
            print(
                json.dumps(
                    {"systemMessage": f"git-workflow: {note}", "suppressOutput": True}
                )
            )
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
