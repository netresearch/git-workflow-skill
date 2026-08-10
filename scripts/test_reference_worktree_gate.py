#!/usr/bin/env python3
"""Cases for reference-worktree-gate.py, run against a throwaway layout.

The negative cases carry the rule: a gate that also blocks `git -C <path>` or a
`cd` into a branch worktree would push the agent back toward the ambiguous form
it exists to discourage.
"""

import importlib.util
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))


def load(root: str):
    os.environ["GIT_WORKTREE_ROOTS"] = root
    spec = importlib.util.spec_from_file_location(
        "gate", os.path.join(HERE, "reference-worktree-gate.py")
    )
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def main() -> int:
    with tempfile.TemporaryDirectory() as root:
        proj = os.path.join(root, "demo")
        os.makedirs(os.path.join(proj, ".bare"))
        os.makedirs(os.path.join(proj, "main"))
        os.makedirs(os.path.join(proj, "feat-x"))
        # A same-named directory WITHOUT a .bare sibling: an ordinary clone.
        plain = os.path.join(root, "plain")
        os.makedirs(os.path.join(plain, "main"))

        gate = load(root)
        ref = os.path.join(proj, "main")
        branch = os.path.join(proj, "feat-x")

        cases = [
            (
                "commit in the reference worktree",
                True,
                "git add -A && git commit -S --no-edit -q",
                ref,
            ),
            (
                "merge in the reference worktree",
                True,
                "git merge origin/main --no-edit",
                ref,
            ),
            (
                "hard reset in the reference worktree",
                True,
                "git reset --hard origin/main",
                ref,
            ),
            (
                "cd to a branch worktree first",
                False,
                f"cd {branch} && git commit -q -m x",
                ref,
            ),
            ("git -C names the target", False, f"git -C {branch} commit -q -m x", ref),
            ("read", False, "git log --oneline -3", ref),
            ("fetch", False, "git fetch origin -q", ref),
            ("worktree add", False, "git worktree add ../y -b y origin/main", ref),
            (
                "commit in a branch worktree",
                False,
                "git add -A && git commit -q -m x",
                branch,
            ),
            (
                "no .bare sibling",
                False,
                "git commit -q -m x",
                os.path.join(plain, "main"),
            ),
            ("not a git write", False, "git status", ref),
            # Refreshing the reference checkout is the directory's purpose: it
            # must be current to serve as the base for new worktrees. Caught by
            # the gate itself minutes after it was installed.
            (
                "ff-only merge refreshes the reference",
                False,
                "git merge --ff-only origin/main",
                ref,
            ),
            ("ff-only pull refreshes the reference", False, "git pull --ff-only", ref),
            # A plain merge still lands a merge commit there.
            ("plain merge is still refused", True, "git merge origin/main", ref),
            # `reset --hard` reaches the same state by discarding, which is the
            # case worth stopping.
            ("hard reset is still refused", True, "git reset --hard origin/main", ref),
        ]

        fails = 0
        for name, want, cmd, cwd in cases:
            got = gate.denies(cmd, cwd)
            ok = got == want
            fails += 0 if ok else 1
            print(
                f"  {'OK  ' if ok else 'FAIL'} {name:36} expected={want!s:5} got={got}"
            )

        # End-to-end through the hook protocol, so the payload shape is covered
        # too — reading tool_input.command, not a top-level "command".
        import json

        p = subprocess.run(
            [sys.executable, os.path.join(HERE, "reference-worktree-gate.py")],
            input=json.dumps(
                {
                    "tool_name": "Bash",
                    "tool_input": {"command": "git commit -m x"},
                    "cwd": ref,
                }
            ),
            capture_output=True,
            text=True,
            check=False,
            env={**os.environ, "GIT_WORKTREE_ROOTS": root},
        )
        e2e = '"deny"' in p.stdout
        fails += 0 if e2e else 1
        print(
            f"  {'OK  ' if e2e else 'FAIL'} {'end-to-end payload':36} expected=True  got={e2e}"
        )

        print("  ---- failures:", fails)
        return 1 if fails else 0


if __name__ == "__main__":
    raise SystemExit(main())
