#!/usr/bin/env bash
# Regression test: verify-git-workflow.sh must run every section.
#
# Two defects made most of the script unreachable, both silent:
#
#   1. `set -e` + `((WARNINGS++))`. Post-increment returns the OLD value, so the
#      first increment of a zero counter exits 1 and set -e aborts the script.
#      Any repository that tripped an early warning got exactly one section and
#      an exit code that read like an ordinary failed verification.
#   2. `[[ ! -d ".git" ]]` as the repository test. In a worktree `.git` is a
#      file, so the script refused to run in the very layout the skill's own
#      references recommend.
#
# Both are invisible from the exit code alone, which is why this test asserts on
# the sections that appear.

set -uo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/skills/git-workflow/scripts/verify-git-workflow.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

fail=0
check() { # check <name> <expected> <actual>
    if [ "$2" = "$3" ]; then
        echo "  ok   $1"
    else
        echo "  FAIL $1: expected '$2', got '$3'"
        fail=1
    fi
}

echo "verify-git-workflow.sh"

# A repo that trips the first warning (non-standard branch name) and several
# later ones: no .gitignore, no CI config, unconventional commits.
repo="$WORK/repo"
mkdir -p "$repo"
git -C "$repo" init -q -b wip-nonstandard
git -C "$repo" config user.name "Probe User"
git -C "$repo" config user.email probe@example.com
echo x > "$repo/a"; git -C "$repo" add a
git -C "$repo" commit -q -m "did some stuff"

out=$(bash "$SCRIPT" "$repo" 2>&1)

for section in "Branch Naming Convention" "Commit Message Format" ".gitignore Check" \
               "Git Hooks" "Code Ownership" "PR Templates" "CI/CD Configuration" \
               "Release Configuration" "Current State" "Conflict Markers" \
               "Commit Signing" "Summary"; do
    check "section runs after an early warning: $section" 1 \
        "$(grep -c "^=== $section ===$" <<<"$out")"
done

# The unsigned commit above must reach the signing section as a warning, not as
# silence — a section that runs but reports nothing is the same blind spot.
check "unsigned commits are reported" 1 \
    "$(grep -c 'carry no signature' <<<"$out")"

# A worktree is a git repository. `.git` is a file there.
git -C "$repo" worktree add -q "$WORK/wt" -b side 2>/dev/null
check "a worktree is recognised as a repository" 0 \
    "$(grep -c 'Not a git repository' <<<"$(bash "$SCRIPT" "$WORK/wt" 2>&1)")"

# A directory that is genuinely not a repository still fails.
mkdir -p "$WORK/plain"
out_plain=$(bash "$SCRIPT" "$WORK/plain" 2>&1)
check "a non-repository is still rejected" 1 "$(grep -c 'Not a git repository' <<<"$out_plain")"

echo
if [ "$fail" -eq 0 ]; then
    echo "All verify-git-workflow section tests passed"
else
    echo "Some verify-git-workflow section tests FAILED"
fi
exit "$fail"
