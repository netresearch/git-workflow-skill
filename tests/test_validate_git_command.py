#!/usr/bin/env python3
"""Cases for scripts/validate_git_command.py.

Run: python3 tests/test_validate_git_command.py

The gates deny commands, so a regression here silently either blocks
legitimate work or stops catching the thing it was written for. Each case
names the failure it stands for.
"""

import json
import os
import pathlib
import re
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
    # A write names its directory (the named-directory gate denies it otherwise);
    # the cd form keeps the legacy `git <verb>` patterns these two cases probe.
    (
        "nested payload reaches the checks",
        "REMINDER",
        'cd /repo && git commit -m "stuff"',
    ),
    (
        "conventional message stays quiet",
        "PASS",
        'cd /repo && git commit -m "fix: handle null"',
    ),
    ("a write without a named directory is denied", "DENY", "git push origin main"),
    ("the same write with -C passes", "PASS", "git -C /repo push origin feat/x"),
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
    # A prefix must not become a bypass: both of these slipped the anchor.
    (
        "env assignment before the call",
        "DENY",
        "env FOO=1 gh api repos/o/r/pulls/comments/1/replies -f body=x",
    ),
    (
        "sudo before the call",
        "DENY",
        "sudo gh api repos/o/r/pulls/comments/1/replies -f body=x",
    ),
    (
        "bare assignment before the call",
        "DENY",
        "GH_TOKEN=x gh api repos/o/r/pulls/comments/1/replies -f body=x",
    ),
    # Second segment of a chain still counts.
    (
        "after && still counts",
        "DENY",
        "git status && gh api repos/o/r/pulls/comments/1/replies -f body=x",
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


def pr_status_path_case(command: str) -> bool:
    """The deny must name an invocable pr-status.sh, not a bare command name.

    The plugin's scripts are not on PATH: a bare `pr-status.sh` produced
    `command not found` (exit 127) and a hunt through the plugin cache
    (2026-08-13). The recommendation must carry the absolute path of the
    script shipped in this plugin, and that path must exist. Both gates
    that recommend the script are exercised, so a later message edit
    cannot drop the interpolation from one of them unnoticed.
    """
    payload = json.dumps({"tool_name": "Bash", "tool_input": {"command": command}})
    proc = subprocess.run(
        [sys.executable, HOOK],
        input=payload,
        capture_output=True,
        text=True,
        timeout=10,
        check=False,
    )
    out = proc.stdout.strip()
    if not out.startswith("{"):
        return False
    reason = json.loads(out)["hookSpecificOutput"].get("permissionDecisionReason", "")
    match = re.search(r"`(/[^`\s]+/pr-status\.sh)", reason)
    return bool(match and os.path.isfile(match.group(1)))


COMMANDS_DIR = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "commands"
)


def shipped_command_blocks():
    """Every ```bash block in commands/*.md, as (file, block) pairs.

    The commands this repo ships are instructions an agent executes verbatim.
    A block that the repo's own gate denies costs a round-trip every time the
    command runs, and reads as the gate misfiring rather than the instruction
    being wrong — which is exactly how it survived: `/pr-finish` step 0 told
    the agent to run `gh pr view --json …mergeStateStatus…` without
    pr-status.sh, and the deny landed twice in one session.
    """
    for md in sorted(pathlib.Path(COMMANDS_DIR).glob("*.md")):
        text = md.read_text()
        for block in re.findall(r"```bash\n(.*?)```", text, re.DOTALL):
            body = "\n".join(
                line.strip() for line in block.splitlines() if line.strip()
            )
            if body:
                yield md.name, body


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

    for name, command in [
        (
            "merge-readiness deny names pr-status.sh path",
            "gh pr view 6651 --json mergeStateStatus",
        ),
        (
            "poll deny names pr-status.sh path",
            "until [ x = y ]; do gh pr view 1 --json state; sleep 30; done",
        ),
    ]:
        ok = pr_status_path_case(command)
        fails += 0 if ok else 1
        print(
            f"  {'OK  ' if ok else 'FAIL'} {name:<44} "
            f"want=abs-path got={'abs-path' if ok else 'bare-name'}"
        )

    denied = 0
    for fname, block in shipped_command_blocks():
        if run(block) == "DENY":
            denied += 1
            print(f"  FAIL shipped block denied in {fname}:\n{block}")
    fails += denied
    if not denied:
        print("  OK   shipped command blocks pass the gate")

    print(f"  ---- failures: {fails}")
    return 1 if fails else 0


if __name__ == "__main__":
    raise SystemExit(main())
