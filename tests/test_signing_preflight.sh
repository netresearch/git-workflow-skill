#!/usr/bin/env bash
# Regression tests for signing-preflight.sh — the mechanical counterpart to the
# signing prose in references/. Every case here is a bug that shipped, or a
# measured claim the docs make and would otherwise never be re-measured:
#
#   %G? / --show-signature report N / "No signature" on a correctly signed SSH
#   commit when gpg.ssh.allowedSignersFile is unset. That is the premise of the
#   header check — if a future git changes it, case 1 fails and the measured
#   claims in commit-conventions.md / pull-request-workflow.md need revisiting.
#
#   grep -q Good over --show-signature matches the Author: line, so an unsigned
#   commit by an author named "Goodwin" reported SIGNING READY.
#
#   ^gpgsig over the whole object matches a message *body* line, so an unsigned
#   commit whose body starts with "gpgsig" reported as signed.
#
# Uses a throwaway ssh key it generates itself, an isolated git config and
# temporary repositories: no network, no agent, no user config.

set -uo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/skills/git-workflow/scripts/signing-preflight.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Isolate from the developer's own git config and ssh-agent: this suite must
# measure the repository it builds, not the machine it runs on.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
unset SSH_AUTH_SOCK

fail=0
check() { # check <name> <expected> <actual>
    if [ "$2" = "$3" ]; then
        echo "  ok   $1"
    else
        echo "  FAIL $1: expected '$2', got '$3'"
        fail=1
    fi
}

KEY="$WORK/id_probe"
ssh-keygen -q -t ed25519 -N "" -C "signing-preflight test" -f "$KEY" \
    || { echo "ssh-keygen unavailable — cannot run signing tests"; exit 1; }

# new_repo <name> [--sha256] [--unsigned]
# Signing points at the *private* key file so it works without an ssh-agent.
# gpg.ssh.allowedSignersFile stays unset on purpose: that is the setup the
# whole design exists for.
new_repo() {
    local dir="$WORK/$1"; shift
    local fmt="sha1" signed=1
    while [ $# -gt 0 ]; do
        case "$1" in
            --sha256)   fmt="sha256" ;;
            --unsigned) signed=0 ;;
        esac
        shift
    done
    mkdir -p "$dir"
    git -C "$dir" init -q -b main --object-format="$fmt"
    git -C "$dir" config user.name "Probe User"
    git -C "$dir" config user.email probe@example.com
    if [ "$signed" -eq 1 ]; then
        git -C "$dir" config gpg.format ssh
        git -C "$dir" config user.signingkey "$KEY"
    fi
    echo "$dir"
}

echo "signing-preflight.sh"

# --- 1. the premise: signed, but local verification says otherwise ----------
repo=$(new_repo premise)
echo seed > "$repo/a"; git -C "$repo" add a
git -C "$repo" commit -q -S -m "chore: seed"
out=$("$SCRIPT" --repo "$repo" 2>&1); rc=$?
check "probe reports READY on an ssh-signing repo" 0 "$rc"
check "probe says SIGNING READY" 1 "$(grep -c 'SIGNING READY' <<<"$out")"
gstatus=$(git -C "$repo" log -1 --format='%G?' 2>/dev/null)
if [ "$gstatus" = "G" ]; then
    echo "  FAIL premise: %G? returned G without gpg.ssh.allowedSignersFile —"
    echo "       git's behaviour changed; re-measure the claims in"
    echo "       references/commit-conventions.md and pull-request-workflow.md"
    fail=1
else
    echo "  ok   premise holds: %G? = '$gstatus' on a correctly signed commit"
fi
check "--check-commit agrees the seed commit is signed" 0 \
    "$("$SCRIPT" --repo "$repo" --check-commit HEAD --quiet; echo $?)"

# --- 2. unsigned commit by an author named Goodwin --------------------------
repo=$(new_repo goodwin --unsigned)
git -C "$repo" config user.name "Alice Goodwin"
echo seed > "$repo/a"; git -C "$repo" add a
git -C "$repo" commit -q -m "chore: seed"
check "an unsigned Goodwin commit is not reported signed" 1 \
    "$("$SCRIPT" --repo "$repo" --check-commit HEAD --quiet; echo $?)"

# --- 3. 'gpgsig' in the message body ----------------------------------------
repo=$(new_repo body --unsigned)
echo seed > "$repo/a"; git -C "$repo" add a
printf 'chore: seed\n\ngpgsig this is not actually a signature\n' > "$WORK/msg.txt"
git -C "$repo" commit -q -F "$WORK/msg.txt"
check "a 'gpgsig' body line is not a signature" 1 \
    "$("$SCRIPT" --repo "$repo" --check-commit HEAD --quiet; echo $?)"

# --- 4. SHA-256 repository writes gpgsig-sha256 -----------------------------
repo=$(new_repo sha256 --sha256)
echo seed > "$repo/a"; git -C "$repo" add a
git -C "$repo" commit -q -S -m "chore: seed"
check "gpgsig-sha256 counts as a signature" 0 \
    "$("$SCRIPT" --repo "$repo" --check-commit HEAD --quiet; echo $?)"

# --- 5. a hook that rejects every message must not read as a signing failure -
repo=$(new_repo hooked)
echo seed > "$repo/a"; git -C "$repo" add a
git -C "$repo" commit -q -S -m "chore: seed"
printf '#!/bin/sh\necho "commit-msg: rejected" >&2\nexit 1\n' > "$repo/.git/hooks/commit-msg"
chmod +x "$repo/.git/hooks/commit-msg"
out=$("$SCRIPT" --repo "$repo" 2>&1); rc=$?
check "a rejecting hook still yields a signing verdict" 0 "$rc"
check "the hook interference is reported" 1 "$(grep -c 'hook rejected the probe' <<<"$out")"

# --- 5b. the same for a pre-commit hook ------------------------------------
repo=$(new_repo prehooked)
echo seed > "$repo/a"; git -C "$repo" add a
git -C "$repo" commit -q -S -m "chore: seed"
printf '#!/bin/sh\nexit 1\n' > "$repo/.git/hooks/pre-commit"
chmod +x "$repo/.git/hooks/pre-commit"
check "a rejecting pre-commit hook still yields a signing verdict" 0 \
    "$("$SCRIPT" --repo "$repo" --quiet; echo $?)"

# --- 6. an unusable signing key is NOT READY, with git's own error ----------
repo=$(new_repo brokenkey)
echo seed > "$repo/a"; git -C "$repo" add a
git -C "$repo" commit -q -S -m "chore: seed"
git -C "$repo" config user.signingkey "$WORK/does-not-exist"
out=$("$SCRIPT" --repo "$repo" 2>&1); rc=$?
check "an unloadable signing key reports NOT READY" 1 "$rc"
check "git's own error is surfaced" 1 "$(grep -c 'NOT READY' <<<"$out")"

# --- 7. the probe leaves nothing behind -------------------------------------
repo=$(new_repo sideeffects)
echo seed > "$repo/a"; git -C "$repo" add a
git -C "$repo" commit -q -S -m "chore: seed"
before_head=$(git -C "$repo" rev-parse HEAD)
before_branch=$(git -C "$repo" symbolic-ref --short HEAD)
echo staged > "$repo/b"; git -C "$repo" add b          # user work sitting in the index
echo dirty > "$repo/c"                                  # and in the worktree
"$SCRIPT" --repo "$repo" --quiet >/dev/null 2>&1
check "HEAD is unchanged"                "$before_head"   "$(git -C "$repo" rev-parse HEAD)"
check "branch is restored"               "$before_branch" "$(git -C "$repo" symbolic-ref --short HEAD)"
check "no probe branch is left behind"   ""               "$(git -C "$repo" branch --list 'tmp/sign-probe*' --format='%(refname:short)')"
check "the staged file is still staged"  "b"              "$(git -C "$repo" diff --cached --name-only)"
check "the untracked file survives"      "dirty"          "$(cat "$repo/c")"

# --- 8. --config-only creates no commit -------------------------------------
repo=$(new_repo configonly)
echo seed > "$repo/a"; git -C "$repo" add a
git -C "$repo" commit -q -S -m "chore: seed"
before_head=$(git -C "$repo" rev-parse HEAD)
"$SCRIPT" --repo "$repo" --config-only --quiet >/dev/null 2>&1
check "--config-only leaves HEAD alone" "$before_head" "$(git -C "$repo" rev-parse HEAD)"

# --- 9. checkpoint GW-17 uses the same rule as the script -------------------
# The checkpoint runs inline in an assessed repository and cannot call this
# script; the two must agree or the checkpoint becomes a second, drifting
# implementation.
repo=$(new_repo checkpoint)
echo seed > "$repo/a"; git -C "$repo" add a
git -C "$repo" commit -q -S -m "chore: seed"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECKPOINTS="$REPO_ROOT/skills/git-workflow/checkpoints.yaml"

# Extracted with awk rather than a YAML parser: CI installs no PyYAML, and a
# test that needs a dependency the runner lacks is a test that does not run.
gw17=$(awk '/^  - id: GW-17$/{f=1} f && /^    pattern: /{sub(/^    pattern: "/, ""); sub(/"$/, ""); print; exit}' "$CHECKPOINTS")

# The checkpoint runner's allowlist (is_safe_eval_command) rejects `$(`, `;`,
# `&&`, `||` and backticks outright, and a multi-line YAML scalar reaches it as
# an empty pattern. A checkpoint that trips either never runs — the exact
# failure this whole branch is about, one layer up.
check "GW-17's pattern is a single line" 1 "$(wc -l <<<"$gw17")"
check "GW-17's pattern has no chaining metacharacters" 0 \
    "$(grep -cE '[;`]|&&|\|\||\$\(' <<<"$gw17")"

# The load-bearing part is the header pattern. Every place that answers "is this
# commit signed" must use the same rule, or one of them silently becomes a
# second, drifting answer — and the weak form `^gpgsig` (no alternation, no
# trailing space) must appear nowhere at all.
RULE='\^gpgsig(-sha256)? '
check "the script uses the shared header rule" 1 \
    "$(grep -c -- "$RULE" "$REPO_ROOT/skills/git-workflow/scripts/signing-preflight.sh")"
check "the checkpoints use the shared header rule" 2 \
    "$(grep -c -- "$RULE" "$CHECKPOINTS")"
check "the verifier uses the shared header rule" 1 \
    "$(grep -c -- "$RULE" "$REPO_ROOT/skills/git-workflow/scripts/verify-git-workflow.sh")"
# Scoped to the shipped surface: this file names the weak form in its own
# assertion text and would otherwise match itself.
check "the weak form appears nowhere under skills/" 0 \
    "$(grep -rl -- "\^gpgsig'" "$REPO_ROOT/skills" 2>/dev/null | wc -l)"

if [ -z "$gw17" ]; then
    echo "  FAIL could not extract the GW-17 command from checkpoints.yaml —"
    echo "       the entry moved or was reformatted; re-anchor this test"
    fail=1
else
    ( cd "$repo" && bash -c "$gw17" ) >/dev/null 2>&1
    check "GW-17 passes on a signed repo" 0 "$?"
    git -C "$repo" -c commit.gpgsign=false commit -q --allow-empty --no-gpg-sign -m "chore: unsigned"
    ( cd "$repo" && bash -c "$gw17" ) >/dev/null 2>&1
    check "GW-17 fails once an unsigned commit lands" 1 "$?"
fi

echo
if [ "$fail" -eq 0 ]; then
    echo "All signing-preflight tests passed"
else
    echo "Some signing-preflight tests FAILED"
fi
exit "$fail"
