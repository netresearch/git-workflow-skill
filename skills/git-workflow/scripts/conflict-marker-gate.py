#!/usr/bin/env -S uv run --script
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: Netresearch DTT GmbH
#
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
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

The check runs in the repository the commit names with `-C`, `--git-dir` or
`--work-tree`; without them, in the current directory. A location written as
a shell variable or command substitution (`-C "$DIR"`) reaches the gate
unexpanded; git cannot find that directory and the gate allows the command.

Fails open: any error, non-repo cwd, or unreadable diff allows the command.
"""

import json
import os
import re
import shlex
import subprocess
import sys

# Real markers are at line start. `=======` alone is excluded on purpose: it is
# a legitimate RST section underline and would fire on every docs commit.
MARKER = re.compile(rb"^(<<<<<<< |>>>>>>> )", re.MULTILINE)

GUIDANCE = (
    "Staged content still contains merge-conflict markers ({files}). "
    "A resolver that exits non-zero does not stop a following `git add && git commit` "
    "— the chain starts fresh. Resolve the markers, re-stage, then commit. "
    "Check with: git diff --cached | grep -n '^<<<<<<< \\|^>>>>>>> '"
)


# Global options that choose the repository a git command runs in. They are
# passed on to the gate's own git calls, so the check reads the repository the
# commit writes to instead of the hook's current directory.
LOCATION_OPTIONS = ("-C", "--git-dir", "--work-tree")

# The location comes from a command the user has not approved yet, so the
# repository it names is untrusted: its config must not run a program while the
# gate reads it. Command-line -c outranks the repository's config.
# - core.fsmonitor runs a program on every index read.
# - A partial clone fetches a missing blob when it is read, through a transport
#   the repository configures (remote.<name>.uploadpack names a program).
#   protocol.allow=never refuses every transport, and GIT_NO_LAZY_FETCH (git
#   2.45+) stops the fetch before a transport is chosen.
# Blobs are read with cat-file, which applies no textconv, and the diff runs
# without external diff drivers.
SAFE_GIT = ("git", "-c", "core.fsmonitor=false", "-c", "protocol.allow=never")
# GIT_ALLOW_PROTOCOL set (empty: no transport) makes git ignore every
# protocol.*.allow entry, which a repository could otherwise set back to
# "always" per protocol and so outrank the -c above.
SAFE_ENV = {**os.environ, "GIT_NO_LAZY_FETCH": "1", "GIT_ALLOW_PROTOCOL": ""}


def commit_locations(command):
    """Location options of each `git commit` in the shell line, one list per commit.

    `git -C ../other commit` yields [["-C", "../other"]]; a plain `git commit`
    yields [[]]. A line without a commit yields [].
    """
    try:
        lexer = shlex.shlex(command, posix=True, punctuation_chars=True)
        lexer.whitespace_split = True
        tokens = list(lexer)
    except ValueError:  # unbalanced quotes — nothing reliable to say
        return []

    commits = []
    for i, token in enumerate(tokens):
        if token != "git":
            continue
        # Skip global options and their values (-C <dir>, -c <k=v>, --git-dir=…)
        location = []
        j = i + 1
        while j < len(tokens) and tokens[j].startswith("-"):
            option = tokens[j]
            name, has_value, value = option.partition("=")
            if option in ("-C", "-c", "--git-dir", "--work-tree"):
                j += 1
                if option in LOCATION_OPTIONS and j < len(tokens):
                    location += [option, os.path.expanduser(tokens[j])]
            elif has_value and name in LOCATION_OPTIONS[1:]:
                # No tilde expansion: bash leaves `--git-dir=~/x` as it is, so
                # git receives the tilde, and the gate must read the same path.
                location.append(f"{name}={value}")
            j += 1
        if j < len(tokens) and tokens[j] == "commit":
            commits.append(location)
    return commits


def marker_count(location, revision_path):
    """Conflict markers in a blob such as ':path' or 'HEAD:path'; 0 if it does not exist.

    The blob is read as bytes: a file that is not valid UTF-8 must still be
    counted instead of ending the gate with a decoding error.
    """
    blob = subprocess.run(
        [*SAFE_GIT, *location, "cat-file", "blob", revision_path],
        capture_output=True,
        env=SAFE_ENV,
        timeout=10,
        check=False,
    )
    if blob.returncode != 0:
        return 0
    return len(MARKER.findall(blob.stdout))


def staged_conflict_files(location):
    """Names of staged files whose staged content adds conflict markers.

    A file counts only when its staged content holds more markers than the
    committed version: documentation that shows a conflict as an example
    already carries markers on HEAD, and every later commit to it would be
    denied otherwise.
    """
    try:
        # -z: NUL-separated raw names; without it git quotes non-ASCII names
        # and `git show` cannot resolve the quoted form.
        names = subprocess.run(
            [
                *SAFE_GIT,
                *location,
                "diff",
                "--no-ext-diff",
                "--no-textconv",
                "--cached",
                "--name-only",
                "-z",
                "--diff-filter=ACMR",
            ],
            capture_output=True,
            env=SAFE_ENV,
            timeout=10,
            check=False,
        )
        if names.returncode != 0:
            return []
        hits = []
        for name in names.stdout.split(b"\0"):
            if not name:
                continue
            staged = marker_count(location, b":" + name)
            if staged > marker_count(location, b"HEAD:" + name):
                hits.append(name.decode("utf-8", "replace"))
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
    if not command:
        return 0

    files = []
    for location in commit_locations(command):
        files += [f for f in staged_conflict_files(location) if f not in files]
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
