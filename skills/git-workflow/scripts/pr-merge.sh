#!/usr/bin/env bash
# pr-merge.sh — merge a pull request with the method the repository allows,
# and only when the merge gate is actually open.
#
# Why this exists: `gh pr merge --merge --delete-branch` is wrong in two common
# repository configurations and gives no useful error until it fails. A repo
# with `allow_merge_commit: false` answers "Merge commits are not allowed on
# this repository"; a repo with a merge queue answers "Cannot use --delete-branch
# when merge queue enabled". Hand-rolling the detection per call site is how a
# 54-repository rollout hit both, three times each. pr-status.sh already knows
# the answer — this reads it instead of guessing.
#
# Squash is never used: it discards atomic commits and their signatures.
#
# Usage:
#   pr-merge.sh                       # PR for the current branch
#   pr-merge.sh 123
#   pr-merge.sh -R owner/repo 123
#   pr-merge.sh -R owner/repo 123 --dry-run   # print the command, run nothing
#
# Exit codes: 0 merged (or queued), 1 the gate is shut, 2 usage/lookup error.
set -uo pipefail

REPO=""; PR=""; DRY=0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

die() { printf 'pr-merge: %s\n' "$1" >&2; exit 2; }
need() { [ $# -ge 2 ] && [ -n "${2:-}" ] || die "$1 requires a value"; }

while [ $# -gt 0 ]; do
  case "$1" in
    -R|--repo) need "$@"; REPO="$2"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) die "unknown flag: $1" ;;
    *)  PR="$1"; shift ;;
  esac
done

command -v gh >/dev/null || die "gh not found"
command -v jq >/dev/null || die "jq not found"
[ -x "$SCRIPT_DIR/pr-status.sh" ] || die "pr-status.sh not found next to this script"

STATUS=$("$SCRIPT_DIR/pr-status.sh" ${REPO:+-R "$REPO"} ${PR:+"$PR"} --json) \
  || die "pr-status.sh failed"

read -r ACTION WHY REPO PR QUEUE METHODS <<EOF
$(printf '%s' "$STATUS" | jq -r '
  [ .next.action,
    (.next.why // "-" | gsub(" ";" ")),
    .repo,
    (.number|tostring),
    (.queue_active|tostring),
    (.merge_methods|join(","))
  ] | @tsv')
EOF
WHY=${WHY//$' '/ }

if [ "$ACTION" != "merge" ]; then
  printf 'pr-merge: not merging %s#%s — %s: %s\n' "$REPO" "$PR" "$ACTION" "$WHY" >&2
  exit 1
fi

# pr-status reports the method it picked; fall back to the allowed list. Squash
# is excluded on purpose even when it is the only method the repo offers — in
# that case pr-status already answers `blocked` and we never get here.
METHOD=$(printf '%s' "$STATUS" | jq -r '.next.method // ""')
if [ -z "$METHOD" ]; then
  case ",$METHODS," in
    *,merge,*)  METHOD="--merge" ;;
    *,rebase,*) METHOD="--rebase" ;;
    *) die "repo allows only [$METHODS] — enable merge or rebase, squash is not used" ;;
  esac
fi

# A merge queue rejects --delete-branch outright, and deletes the branch itself
# once the entry merges.
CMD=(gh pr merge "$PR" --repo "$REPO" "$METHOD")
[ "$QUEUE" = "true" ] || CMD+=(--delete-branch)

if [ "$DRY" = "1" ]; then
  printf '%q ' "${CMD[@]}"; printf '\n'
  exit 0
fi

OUT=$("${CMD[@]}" 2>&1); RC=$?
if [ "$RC" -ne 0 ]; then
  printf 'pr-merge: %s#%s failed: %s\n' "$REPO" "$PR" "$(printf '%s' "$OUT" | tr '\n' ' ')" >&2
  exit 1
fi

if [ "$QUEUE" = "true" ]; then
  printf 'pr-merge: %s#%s queued (%s, strategy set by the queue)\n' "$REPO" "$PR" "$METHOD"
else
  printf 'pr-merge: %s#%s merged (%s)\n' "$REPO" "$PR" "$METHOD"
fi
