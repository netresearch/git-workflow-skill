#!/usr/bin/env python3
"""PreToolUse hook for Bash: deny `git commit` while staged content still carries
merge-conflict markers.

Why this exists: a resolver script that aborts does NOT stop a following
`git add -A && git commit` in the same Bash call — the `&&` chain starts fresh
after the failed command, so the commit lands with `<<<<<<<` in the tree.
Observed twice in one session (2026-08-09, netresearch/t3x-nr-llm) during a
batch-merge, caught only by a later gate run and costing a full test cycle each
time.

verify-git-workflow.sh checks the working tree on demand; this is the
commit-time gate, and it looks at staged content for every file extension.

Wire it as a PreToolUse hook with matcher "Bash" — see
references/claude-code-hooks.md, Recipe 6.

Fails open: any error, non-repo cwd, or unreadable diff allows the command.
"""

import json
import re
import shlex
import subprocess
import sys

# Real markers are at line start. `=======` alone is excluded on purpose: it is
# a legitimate RST section underline and would fire on every docs commit.
MARKER = re.compile(r"^(<<<<<<< |>>>>>>> )", re.MULTILINE)

GUIDANCE = (
    "Staged content still contains merge-conflict markers ({files}). "
    "A resolver that exits non-zero does not stop a following `git add && git commit` "
    "— the chain starts fresh. Resolve the markers, re-stage, then commit. "
    "Check with: git diff --cached | grep -n '^<<<<<<< \\|^>>>>>>> '"
)


def is_git_commit(command):
    """True when the command runs `git commit` in any segment of the shell line."""
    try:
        lexer = shlex.shlex(command, posix=True, punctuation_chars=True)
        lexer.whitespace_split = True
        tokens = list(lexer)
    except ValueError:  # unbalanced quotes — nothing reliable to say
        return False

    for i, token in enumerate(tokens):
        if token != "git":
            continue
        # Skip global options and their values (-C <dir>, -c <k=v>, --git-dir=…)
        j = i + 1
        while j < len(tokens) and tokens[j].startswith("-"):
            if tokens[j] in ("-C", "-c", "--git-dir", "--work-tree"):
                j += 1
            j += 1
        if j < len(tokens) and tokens[j] == "commit":
            return True
    return False


def staged_conflict_files():
    """Names of staged files whose staged content carries conflict markers."""
    try:
        names = subprocess.run(
            ["git", "diff", "--cached", "--name-only", "--diff-filter=ACMR"],
            capture_output=True,
            text=True,
            timeout=10,
            check=False,
        )
        if names.returncode != 0:
            return []
        hits = []
        for name in names.stdout.split("\n"):
            name = name.strip()
            if not name:
                continue
            blob = subprocess.run(
                ["git", "show", f":{name}"],
                capture_output=True,
                text=True,
                timeout=10,
                check=False,
            )
            if blob.returncode == 0 and MARKER.search(blob.stdout):
                hits.append(name)
            if len(hits) >= 5:
                break
        return hits
    except (subprocess.SubprocessError, OSError):
        return []


def main():
    try:
        payload = json.load(sys.stdin)
    except (json.JSONDecodeError, ValueError):
        return 0

    command = (payload.get("tool_input") or {}).get("command") or ""
    if not command or not is_git_commit(command):
        return 0

    files = staged_conflict_files()
    if not files:
        return 0

    print(
        json.dumps(
            {
                "hookSpecificOutput": {
                    "hookEventName": "PreToolUse",
                    "permissionDecision": "deny",
                    "permissionDecisionReason": GUIDANCE.format(files=", ".join(files)),
                }
            }
        )
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
