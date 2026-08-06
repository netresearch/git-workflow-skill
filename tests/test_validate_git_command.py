#!/usr/bin/env python3
"""Cases for scripts/validate_git_command.py.

Run: python3 tests/test_validate_git_command.py

The gates deny commands, so a regression here silently either blocks
legitimate work or stops catching the thing it was written for. Each case
names the failure it stands for.
"""

import json
import os
import subprocess
import sys
import tempfile

HOOK = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "scripts",
    "validate_git_command.py",
)

WRAPPED = (
    "A paragraph wrapped by hand at roughly the seventy-two column mark,\n"
    "which is the shape this gate exists to catch before it is posted and\n"
    "the breaks survive verbatim in the rendered release notes forever.\n"
    "A fourth line so the run is unambiguously a wrapped paragraph."
)

CASES = [
    # (name, expected, command)
    # The bug that made every check below unreachable: the payload is nested.
    ("nested payload reaches the checks", "REMINDER", 'git commit -m "stuff"'),
    ("conventional message stays quiet", "PASS", 'git commit -m "fix: handle null"'),
    (
        "reply path without the PR number",
        "DENY",
        "gh api repos/o/r/pulls/comments/123/replies -f body=x",
    ),
    # Legitimate read endpoint - same prefix, no /replies.
    (
        "reading one comment is allowed",
        "PASS",
        "gh api repos/o/r/pulls/comments/123",
    ),
    # Writing ABOUT the path must not be blocked, only invoking it.
    (
        "the path inside an echo is not a call",
        "PASS",
        "echo 'use repos/o/r/pulls/comments/1/replies'",
    ),
    (
        "sleep-loop over PR state",
        "DENY",
        "until [ x = y ]; do gh pr view 1 --json state; sleep 30; done",
    ),
    (
        "pr-status.sh --watch is the fix, not the fault",
        "PASS",
        "pr-status.sh -R o/r 1 --watch",
    ),
    (
        "a single gh pr view is not a poll",
        "PASS",
        "gh pr view 1 --repo o/r --json state",
    ),
    ("hard-wrapped inline body", "DENY", f'gh pr create --title x --body "{WRAPPED}"'),
    (
        "one long line is what we want",
        "PASS",
        'gh pr create --title x --body "One long line that the renderer reflows by itself."',
    ),
    ("unrelated command", "PASS", "ls -la"),
]


def run(command: str) -> str:
    payload = json.dumps({"tool_name": "Bash", "tool_input": {"command": command}})
    # check=False: a non-zero exit is itself something the cases assert on,
    # not a reason to abort the run.
    proc = subprocess.run(
        [sys.executable, HOOK],
        input=payload,
        capture_output=True,
        text=True,
        timeout=10,
        check=False,
    )
    out = proc.stdout.strip()
    if not out:
        return "PASS"
    if out.startswith("{"):
        decision = json.loads(out)["hookSpecificOutput"]["permissionDecision"]
        return "DENY" if decision == "deny" else "PASS"
    return "REMINDER"


def fifo_case() -> bool:
    """A --body-file naming a pipe must not block the hook.

    `gh pr create --body-file <(generate)` hands over /dev/fd/N. Opening it
    here waits for a writer this process cannot see, and the hook hangs.
    """
    tmp = tempfile.mkdtemp()
    path = os.path.join(tmp, "fifo")
    os.mkfifo(path)
    try:
        run(f"gh pr create --title x --body-file {path}")
        return True
    except subprocess.TimeoutExpired:
        return False
    finally:
        os.unlink(path)
        os.rmdir(tmp)


def main() -> int:
    fails = 0
    for name, expected, command in CASES:
        got = run(command)
        ok = got == expected
        fails += 0 if ok else 1
        print(f"  {'OK  ' if ok else 'FAIL'} {name:<44} want={expected:<9} got={got}")

    ok = fifo_case()
    fails += 0 if ok else 1
    print(
        f"  {'OK  ' if ok else 'FAIL'} {'--body-file on a pipe returns':<44} want=no-hang  "
        f"got={'no-hang' if ok else 'HUNG'}"
    )

    print(f"  ---- failures: {fails}")
    return 1 if fails else 0


if __name__ == "__main__":
    raise SystemExit(main())
