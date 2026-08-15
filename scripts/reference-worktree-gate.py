#!/usr/bin/env python3
"""PreToolUse gate: refuse a git write inside a reference `main/` worktree.

In the bare-repo layout (`<project>/.bare` + one directory per branch), `main/`
exists to be read, fetched from, and used as the base for new worktrees.
`references/advanced-git.md` states that and so do most AGENTS.md files that
adopt the layout. The rule still gets broken, because breaking it needs no
intent: one Bash call omits its `cd`, inherits the working directory of an
earlier call, and the commit lands on the shared branch locally — where a later
push or a `jj git export` moves it under every sibling worktree.

This denies the write. It does not deny naming the target explicitly:
`git -C <path> commit` and `cd <path> && git commit` both pass, because both say
where the write lands.

Fails open. Any error, an unreadable payload, or a directory outside the layout
allows the command — a gate that blocks on its own failure is worse than the
friction it prevents.
"""

import json
import os
import re
import sys

# `<root>/<project>/main` (or `master`) — the reference checkout of the layout.
# Set GIT_WORKTREE_ROOTS to a colon-separated list to match other roots.
DEFAULT_ROOTS = ("~/projects", "~/p")

# Subcommands that leave a commit, an index entry, or rewritten history behind.
# `add` is included deliberately: the damage this gate exists to stop starts
# with a stray `git add -A` staging a directory nobody meant to touch.
GIT_WRITE = re.compile(
    r"\bgit\s+(?:commit|add|merge|rebase|cherry-pick|revert|am|stash)\b"
    r"|\bgit\s+reset\s+--hard\b"
    # Moving the reference checkout to another branch is the same damage one
    # step earlier: the directory stops holding `main`, every later write lands
    # on the wrong branch, and a sibling session reading it sees the branch
    # change under it mid-edit. 48 such switches happened in one session on a
    # machine where only prose forbade it. Returning it to main/master is
    # allowed, and so is `git checkout -- <path>` (a file restore, not a
    # branch move) — the trailing-token form below never matches that.
    r"|\bgit\s+(?:checkout|switch)\s+(?:-[a-zA-Z]*\s+)*-[bcB]\b"
)
# A plain switch to a named branch: `git checkout feature/x`. Excluded are
# `main`, `master` and `-` (going back is the point), and anything with a `--`
# or a path, which is a restore rather than a branch move.
BRANCH_SWITCH = re.compile(r"\bgit\s+(?:checkout|switch)\s+(?!-)(?!--)([\w./-]+)\s*$")
# `git -C <path>` moves the operation out of the working directory, so the
# working directory no longer decides where the write lands. That is the
# explicit form this gate asks for, so it is never blocked.
GIT_DASH_C = re.compile(r"\bgit\s+-C\s+\S+")
# Bringing the reference checkout up to date is what the directory is FOR — it
# has to be current to serve as the base for new worktrees. A fast-forward
# cannot create a commit or discard work, so `merge --ff-only` / `pull --ff-only`
# are the sanctioned refresh and stay allowed. `reset --hard` is not: it reaches
# the same state by discarding, which is the case worth stopping.
FAST_FORWARD_ONLY = re.compile(r"\bgit\s+(?:merge|pull)\b[^|&;]*--ff-only\b")


def roots() -> list[str]:
    raw = os.environ.get("GIT_WORKTREE_ROOTS")
    parts = raw.split(":") if raw else DEFAULT_ROOTS
    return [os.path.realpath(os.path.expanduser(p)) for p in parts if p]


def effective_dir(cmd: str, cwd: str) -> str:
    """The directory the command runs in: the last `cd` in the call wins."""
    last = None
    for m in re.finditer(r"(?:^|[|&;\n])\s*cd\s+([^\s|&;]+)", cmd or ""):
        last = m.group(1).strip("'\"")
    return last or (cwd or "")


def is_reference_worktree(path: str) -> bool:
    """True for `<root>/<project>/main` that sits beside a `.bare`.

    Both halves matter. Without the name check every worktree matches; without
    the `.bare` check an ordinary clone whose directory happens to be called
    `main` would be gated.
    """
    d = os.path.realpath(os.path.expanduser(path or "")).rstrip("/")
    if os.path.basename(d) not in ("main", "master"):
        return False
    parent = os.path.dirname(d)
    if not any(os.path.dirname(parent) == r for r in roots()):
        return False
    return os.path.isdir(os.path.join(parent, ".bare"))


def switches_branch(cmd: str) -> bool:
    """True for a plain switch to a branch other than main/master/-."""
    m = BRANCH_SWITCH.search(cmd)
    return bool(m) and m.group(1) not in ("main", "master", "-")


def denies(cmd: str, cwd: str) -> bool:
    c = (cmd or "").strip()
    if "git worktree" in c:
        return False
    if not (GIT_WRITE.search(c) or switches_branch(c)):
        return False
    if GIT_DASH_C.search(c) or FAST_FORWARD_ONLY.search(c):
        return False
    return is_reference_worktree(effective_dir(c, cwd))


REASON = (
    "This is a git write or a branch switch inside a reference `main/` worktree. "
    "That directory is for reading, for `git fetch`, and as the base for new "
    "worktrees; work belongs in its own worktree beside it:\n\n"
    "  git worktree add -b <branch> ../<branch> && cd ../<branch>\n\n"
    "Usually the cause is an inherited working directory rather than intent — a "
    "previous call left the shell somewhere else. Name the target:\n\n"
    "  cd <project>/<branch> && git commit …\n"
    "  git -C <project>/<branch> commit …\n\n"
    "`git -C <path>` is never blocked, and neither is the reference checkout's own "
    "refresh — `git merge --ff-only origin/main` / `git pull --ff-only`. Reads, "
    "`git fetch` and `git worktree add` are unaffected."
)


def main() -> int:
    try:
        payload = json.loads(sys.stdin.read() or "{}")
    except Exception:  # noqa: BLE001 - hook entry point: fail open
        return 0
    if not isinstance(payload, dict) or payload.get("tool_name") != "Bash":
        return 0
    cmd = (payload.get("tool_input") or {}).get("command", "")
    try:
        if denies(cmd, payload.get("cwd", "")):
            print(
                json.dumps(
                    {
                        "hookSpecificOutput": {
                            "hookEventName": "PreToolUse",
                            "permissionDecision": "deny",
                            "permissionDecisionReason": REASON,
                        }
                    }
                )
            )
    except Exception:  # noqa: BLE001 - fail open
        return 0
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
