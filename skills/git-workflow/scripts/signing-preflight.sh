#!/usr/bin/env bash
# signing-preflight.sh — does `git commit -S` actually produce a signature here?
#
# Answers the one question a commit-heavy run needs answered up front, and
# answers it from the commit object rather than from local verification:
#
#   git log --show-signature / %G?  →  "can THIS MACHINE verify the signature"
#   gpgsig header in the object     →  "did git WRITE a signature"
#
# Those differ. With gpg.format=ssh and no gpg.ssh.allowedSignersFile, git
# 2.54.0 reports `%G? = N` and `No signature` for a perfectly signed commit —
# indistinguishable from unsigned, and it exits 0 while printing the error, so
# a driver reading $? sees success. Whether the *host* accepts the key is a
# third question again, answered only by the GitHub commits API.
#
# The probe never touches the working tree, the index or the current branch:
# it commits on a throwaway branch through a temporary index and removes both.
#
# Usage: signing-preflight.sh [--config-only] [--check-commit <rev>]
#                             [--repo <dir>] [--quiet]
#
#   (default)         probe: prove that `git commit -S` signs, here, now
#   --config-only     report the signing config without creating a commit
#   --check-commit    report whether an existing commit carries a signature
#
# Exit codes:
#   0  READY / signed
#   1  NOT READY / unsigned — no signature, or the commit aborted with hooks
#                     already ruled out by the --no-verify retry
#   2  INCONCLUSIVE — --config-only cannot answer from the config alone
#   3  USAGE        — not a git repository / bad arguments

set -uo pipefail

CONFIG_ONLY=0
QUIET=0
REPO_DIR="."
CHECK_REV=""

while [ $# -gt 0 ]; do
    case "$1" in
        --config-only)  CONFIG_ONLY=1 ;;
        --check-commit) shift; CHECK_REV="${1:-}" ;;
        --quiet)        QUIET=1 ;;
        --repo)         shift; REPO_DIR="${1:-}" ;;
        -h|--help)      sed -n '2,30p' "$0"; exit 0 ;;
        *)              echo "unknown argument: $1" >&2; exit 3 ;;
    esac
    shift
done

say() { [ "$QUIET" -eq 1 ] || printf '%s\n' "$*"; }

cd "$REPO_DIR" 2>/dev/null || { echo "no such directory: $REPO_DIR" >&2; exit 3; }
git rev-parse --git-dir >/dev/null 2>&1 || { echo "not a git repository: $REPO_DIR" >&2; exit 3; }

# --- the check itself -------------------------------------------------------
# Both backends write the signature as a commit *header*: `gpgsig` (SHA-1
# repositories) or `gpgsig-sha256` (SHA-256), carrying `-----BEGIN SSH
# SIGNATURE-----` or `-----BEGIN PGP SIGNATURE-----`. No local config gates it.
#
# Cut the object at the first blank line before matching: over the whole
# object, `^gpgsig` also matches a message *body* line that starts with
# `gpgsig`, which reports an unsigned commit as signed.
commit_carries_signature() {
    git cat-file commit "$1" 2>/dev/null | sed -n '/^$/q;p' | grep -qE '^gpgsig(-sha256)? '
}

if [ -n "$CHECK_REV" ]; then
    git rev-parse --verify --quiet "${CHECK_REV}^{commit}" >/dev/null \
        || { echo "no such commit: $CHECK_REV" >&2; exit 3; }
    if commit_carries_signature "$CHECK_REV"; then
        say "signed: $CHECK_REV carries a signature header"
        exit 0
    fi
    say "unsigned: $CHECK_REV carries no signature header"
    exit 1
fi

# --- configuration ----------------------------------------------------------
gpgsign=$(git config --get commit.gpgsign || echo "")
gpgformat=$(git config --get gpg.format || echo "openpgp")
signingkey=$(git config --get user.signingkey || echo "")

say "config: commit.gpgsign=${gpgsign:-<unset>} gpg.format=$gpgformat user.signingkey=${signingkey:-<unset>}"

if [ "$gpgformat" = "ssh" ] && command -v ssh-add >/dev/null 2>&1; then
    if ! ssh-add -l >/dev/null 2>&1; then
        # Not fatal: user.signingkey may name a private key file, which signs
        # without an agent. Worth reporting, since a dropped agent key is the
        # most common cause of a mid-run signing failure.
        say "note: ssh-agent holds no identities — signing works only if user.signingkey names a private key file"
    fi
fi

if [ "$CONFIG_ONLY" -eq 1 ]; then
    if [ -z "$signingkey" ] && [ "$gpgformat" = "ssh" ]; then
        say "INCONCLUSIVE — gpg.format=ssh without user.signingkey; config cannot tell whether signing works"
        exit 2
    fi
    say "config present — run without --config-only to prove signing actually works"
    exit 0
fi

# --- probe ------------------------------------------------------------------
PROBE_BRANCH="tmp/sign-probe-$$"
ORIG_REF=$(git symbolic-ref -q --short HEAD || git rev-parse --verify HEAD 2>/dev/null || echo "")
TMP_INDEX=$(mktemp)
STDERR_LOG=$(mktemp)

# shellcheck disable=SC2329  # invoked by the EXIT trap below
cleanup() {
    # Restore first, then drop the branch: a branch cannot be deleted while
    # it is checked out.
    if [ -n "$ORIG_REF" ]; then
        git checkout -q "$ORIG_REF" -- 2>/dev/null || git checkout -q "$ORIG_REF" 2>/dev/null || true
    fi
    git branch -q -D "$PROBE_BRANCH" 2>/dev/null || true
    rm -f "$TMP_INDEX" "$STDERR_LOG"
}
trap cleanup EXIT

# A temporary index seeded from HEAD keeps the real index untouched — without
# it, `commit --allow-empty` sweeps whatever the user had staged into the
# throwaway commit and unstages it when the branch is deleted.
export GIT_INDEX_FILE="$TMP_INDEX"
if git rev-parse --verify HEAD >/dev/null 2>&1; then
    git read-tree HEAD || { echo "could not seed temporary index" >&2; exit 3; }
fi

git checkout -q -b "$PROBE_BRANCH" 2>/dev/null || { echo "could not create probe branch" >&2; exit 3; }

# Conventional message: a commit-msg hook rejecting `probe` aborts the commit
# and is indistinguishable from a signing failure at the exit code.
probe_commit() { git commit -S --allow-empty "$@" -m "chore: signing probe" >/dev/null 2>"$STDERR_LOG"; }

HOOK_BLOCKED=0
if ! probe_commit; then
    # Retry with hooks off. If it now commits, the first failure was a hook,
    # not signing — a distinction the plain probe cannot make. --no-verify is
    # confined to this throwaway commit, which is deleted moments later.
    if probe_commit --no-verify; then
        HOOK_BLOCKED=1
        say "note: a hook rejected the probe commit; retried with --no-verify to isolate signing"
    else
        # --no-verify skips pre-commit and commit-msg, so hooks are ruled out
        # by the retry: what remains is signing, or the repository itself.
        say "NOT READY — git commit -S aborted with hooks disabled:"
        say "$(sed 's/^/  /' "$STDERR_LOG")"
        exit 1
    fi
fi

if commit_carries_signature HEAD; then
    say "SIGNING READY — the probe commit carries a signature header"
    [ "$HOOK_BLOCKED" -eq 1 ] && say "  (hooks reject a plain probe here; real commits must satisfy them)"
    exit 0
fi

say "NOT READY — the probe commit was created without a signature"
say "  commit.gpgsign is ${gpgsign:-unset}; pass -S explicitly or set commit.gpgsign=true"
exit 1
