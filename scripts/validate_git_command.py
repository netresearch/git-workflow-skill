#!/usr/bin/env python3
"""
PreToolUse hook to validate git commands for best practices.
Checks conventional commits, branch naming, and common mistakes.
"""

import json
import os
import re
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


def forge_body_hard_wrapped(cmd: str) -> str | None:
    if not FORGE_BODY.search(cmd):
        return None
    bodies = []
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
    for name, text in bodies:
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
    for gate in (
        forge_body_hard_wrapped,
        reply_path_without_pr,
        handrolled_pr_poll,
        merge_readiness_without_pr_status,
    ):
        reason = gate(command)
        if reason:
            deny(reason)
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
