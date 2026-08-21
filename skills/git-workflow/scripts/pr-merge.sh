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
#   pr-merge.sh -R owner/repo 123 --self-reviewed
#                                     # the review the gate demands is one an
#                                     # exhausted Copilot quota (or two failed
#                                     # reviews on this head) makes
#                                     # unsatisfiable, and the operator has
#                                     # reviewed the diff instead: post the
#                                     # on-the-record `Self-review: <head-sha>`
#                                     # attestation comment as the PR author,
#                                     # then merge. Refused whenever a live
#                                     # review path still exists, and whenever
#                                     # the authenticated gh user is not the
#                                     # PR author (#203).
#
# Exit codes: 0 merged (or queued) AND confirmed by reading the PR back, 1 the
# gate is shut and nothing was attempted, 2 an error — usage, lookup, the merge
# call itself failed, or it exited 0 while nothing merged and nothing entered
# the queue. 1 is retryable later; 2 needs a human.
set -uo pipefail

# --version answers "which copy am I running" without diffing installations.
# Two installations can declare the SAME number while shipping different
# scripts (netresearch/git-workflow-skill#209 measured exactly that, and the
# missing flag read as a missing feature for a dozen merges). So the resolved
# path is printed beside the version: the number says what the copy claims to
# be, the path says which file actually answered.
#
# The version is read from the SKILL.md NEXT TO the script, never from a
# checkout elsewhere -- a cached copy must report the number it was packaged
# with, or the answer is worse than none. \042 and \047 are the quote
# characters by octal code, so this awk program contains no quote of its own
# to terminate the single-quoted string it lives in.
skill_version() {
    local here skill v
    here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    skill="$here/../SKILL.md"
    v="unknown"
    if [ -f "$skill" ]; then
        v="$(awk '/^[ \t]*version:/ {
                 s = $0
                 sub(/^[ \t]*version:[ \t]*/, "", s)
                 gsub(/[\042\047]/, "", s)
                 gsub(/[ \t\r]+$/, "", s)
                 if (s != "") { print s; exit }
             }' "$skill" 2>/dev/null)" || v=""
        [ -n "$v" ] || v="unknown"
    fi
    printf '%s %s\n' "$(basename "${BASH_SOURCE[0]}")" "$v"
    printf 'path: %s/%s\n' "$here" "$(basename "${BASH_SOURCE[0]}")"
}

REPO=""; PR=""; DRY=0; SELF_REVIEWED=0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

die() { printf 'pr-merge: %s\n' "$1" >&2; exit 2; }
need() { [ $# -ge 2 ] && [ -n "${2:-}" ] || die "$1 requires a value"; }

while [ $# -gt 0 ]; do
  case "$1" in
    -R|--repo) need "$@"; REPO="$2"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    --self-reviewed) SELF_REVIEWED=1; shift ;;
    --version) skill_version; exit 0 ;;
    -h|--help) awk 'NR>1 && /^#/ {sub(/^# ?/,""); print; next} NR>1 {exit}' "$0"; exit 0 ;;
    -*) die "unknown flag: $1" ;;
    *)  PR="$1"; shift ;;
  esac
done

command -v gh >/dev/null || die "gh not found"
command -v jq >/dev/null || die "jq not found"
[ -x "$SCRIPT_DIR/pr-status.sh" ] || die "pr-status.sh not found next to this script"

read_status() {
  STATUS=$("$SCRIPT_DIR/pr-status.sh" ${REPO:+-R "$REPO"} ${PR:+"$PR"} --json) \
    || die "pr-status.sh failed"

  # Tab-separated, read with a tab-only IFS: the default IFS splits on spaces
  # too, which would tear `why` apart, and it collapses an empty field so every
  # later variable shifts by one. `jq -e` turns a schema change or truncated
  # output into a failure here rather than an empty ACTION further down.
  FIELDS=$(printf '%s' "$STATUS" | jq -er '
    [ .next.action,
      (.next.why // "-"),
      .repo,
      (.number|tostring),
      (.queue_active|tostring),
      (.merge_methods|join(","))
    ] | @tsv') || die "pr-status.sh returned unexpected JSON"

  IFS=$'\t' read -r ACTION WHY REPO PR QUEUE METHODS <<EOF
$FIELDS
EOF
  [ -n "$ACTION" ] && [ -n "$REPO" ] && [ -n "$PR" ] || die "pr-status.sh returned no action"
}

read_status

# --self-reviewed: the one refusal this flag may clear is a review demand the
# gate itself calls unsatisfiable (quota wall, or two failed bot reviews on
# this head). The flag does not open the gate directly — it posts the
# on-the-record `Self-review: <head-sha>` attestation comment pr-status.sh
# reads back, then asks again. Everything else about the gate stays exactly
# as strict: any other refusal, a non-author caller, or a live review path
# leaves the flag without effect.
if [ "$SELF_REVIEWED" = "1" ] && [ "$ACTION" = "request-review" ]; then
  SR_FIELDS=$(printf '%s' "$STATUS" | jq -er '
    [ (.next.reason // "-"),
      ((.self_review_on_head // false)|tostring),
      (.headOid // ""), (.author // "")
    ] | @tsv') || die "pr-status.sh returned unexpected JSON"
  IFS=$'\t' read -r SR_REASON SR_HAVE SR_HEAD SR_AUTHOR <<EOF
$SR_FIELDS
EOF
  # Keyed on the reason the REFUSING BRANCH stamped, never re-derived from the
  # account-global quota state: a request-review can also come from e.g. the
  # classic require_last_push_approval gate — a satisfiable human approval —
  # and with the monthly quota marker set on this machine a global test would
  # post a factually false "unsatisfiable" attestation into permanent PR
  # history there.
  if [ "$SR_REASON" != "bot-review-unsatisfiable" ]; then
    die "--self-reviewed refused: this request-review is not the unsatisfiable-bot-review case (reason: $SR_REASON) — a live review path exists, use it"
  fi
  VIEWER=$(gh api user --jq .login 2>/dev/null) || die "--self-reviewed: could not resolve the authenticated gh user"
  if [ "$VIEWER" != "$SR_AUTHOR" ]; then
    die "--self-reviewed refused: the attestation must come from the PR author ($SR_AUTHOR); gh is authenticated as $VIEWER"
  fi
  if [ "$SR_HAVE" != "true" ]; then
    BODY=$(printf 'Self-review: %s\n\nThe review this pull request demands is unsatisfiable (Copilot quota wall or repeated bot failures on this head). Per the documented fallback, the diff on this head was reviewed by the PR author; this comment is the on-the-record attestation the merge gate reads back. It stops matching on the next push.' "$SR_HEAD")
    if [ "$DRY" = "1" ]; then
      # A dry run must not flip persistent gate state: the attestation comment
      # IS the gate-opening write, so it is previewed, never posted.
      printf 'pr-merge: dry-run — would post the Self-review attestation for %s on %s#%s, re-read the gate and merge\n' "${SR_HEAD:0:12}" "$REPO" "$PR"
      exit 0
    fi
    gh pr comment "$PR" --repo "$REPO" --body "$BODY" >/dev/null \
      || die "--self-reviewed: posting the attestation comment failed"
    printf 'pr-merge: posted Self-review attestation for %s on %s#%s\n' "${SR_HEAD:0:12}" "$REPO" "$PR" >&2
  fi
  read_status
fi

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
  exit 2
fi

# Exiting 0 is not proof that anything happened. On a repository with a merge
# queue, `gh pr merge --merge` prints its usual success line and adds NOTHING to
# the queue when an auto-merge request is already attached to the PR: the
# pending request swallows the enqueue. Observed twice on one repository —
# immediately after the call `isInMergeQueue` was false and the queue was empty;
# after `gh pr merge <n> --disable-auto` the identical call put the PR at
# position 1. Relaying the exit status as "queued" asserted a state that did not
# exist and cost hours of misdiagnosis, so the outcome is read back before it is
# claimed. This script reports; clearing the auto-merge request is the caller's
# decision, not a side effect of asking to merge.
OWNER="${REPO%%/*}"; NAME="${REPO##*/}"

outcome() {
  # shellcheck disable=SC2016  # $owner/$name/$pr are GraphQL variables, not shell
  gh api graphql -f owner="$OWNER" -f name="$NAME" -F pr="$PR" -f query='
  query($owner:String!,$name:String!,$pr:Int!){
    repository(owner:$owner,name:$name){
      pullRequest(number:$pr){
        state isInMergeQueue autoMergeRequest{ enabledBy{ login } }
      }
    }
  }' 2>/dev/null
}

# A queue entry is registered asynchronously, so the first read can legitimately
# answer false for an entry that lands a second later. The poll is bounded: a PR
# that has not appeared by then does not appear on its own, and a longer wait
# would be paid by every successful merge too.
STATE=""; INQ=""; AUTOBY="-"; PROBED=0; ATTEMPT=0
while :; do
  ATTEMPT=$((ATTEMPT + 1))
  if Q=$(outcome) && F=$(printf '%s' "$Q" | jq -er '.data.repository.pullRequest
        | [ .state, (.isInMergeQueue | tostring),
            (.autoMergeRequest.enabledBy.login // "-") ] | @tsv'); then
    IFS=$'\t' read -r STATE INQ AUTOBY <<EOF
$F
EOF
    PROBED=1
    [ "$STATE" = "MERGED" ] && break
    # Keyed on what the PR reports, not on the repo-level QUEUE flag: an entry
    # that exists is an entry, whatever the configuration said a moment ago.
    [ "$INQ" = "true" ] && break
  fi
  [ "$ATTEMPT" -ge 5 ] && break
  sleep 2
done

if [ "$STATE" = "MERGED" ]; then
  printf 'pr-merge: %s#%s merged (%s)\n' "$REPO" "$PR" "$METHOD"
  exit 0
fi
if [ "$INQ" = "true" ]; then
  printf 'pr-merge: %s#%s queued (%s, strategy set by the queue)\n' "$REPO" "$PR" "$METHOD"
  exit 0
fi

# Nothing landed. A probe that failed is kept apart from a probe that succeeded
# and saw nothing: an unreachable API says something about the request, not
# about the PR, and folding the two together would put a transport failure on
# the record as a fact about GitHub state. Both exit 2 — what this block exists
# for is to stop reporting an outcome that was never confirmed.
if [ "$PROBED" = "0" ]; then
  {
    printf 'pr-merge: %s#%s: the merge call exited 0 but the outcome could not be\n' "$REPO" "$PR"
    printf '  read back — %d GraphQL attempt(s) failed. Whether it merged or was\n' "$ATTEMPT"
    printf '  enqueued is unknown; establish that before reporting anything:\n'
    printf '    gh pr view %s --repo %s --json state,mergedAt\n' "$PR" "$REPO"
  } >&2
  exit 2
fi

if [ "$QUEUE" = "true" ]; then
  OBSERVED="not in the merge queue (state=$STATE, isInMergeQueue=$INQ)"
else
  OBSERVED="not merged (state=$STATE)"
fi
{
  printf 'pr-merge: %s#%s failed: gh pr merge %s exited 0 but the PR is %s\n' \
    "$REPO" "$PR" "$METHOD" "$OBSERVED"
  if [ "$AUTOBY" != "-" ]; then
    printf '  An auto-merge request enabled by %s is attached to this PR. A pending\n' "$AUTOBY"
    printf '  auto-merge request swallows the enqueue: the call succeeds, the queue\n'
    printf '  stays empty, and neither gh pr checks nor mergeStateStatus shows it.\n'
    printf '  Clear it, then run this script again:\n'
    printf '    gh pr merge %s --repo %s --disable-auto\n' "$PR" "$REPO"
  else
    printf '  No auto-merge request is attached, so the usual cause (a pending one\n'
    printf '  swallowing the enqueue) is ruled out here. Re-read the gate before\n'
    printf '  retrying:\n'
    printf '    pr-status.sh -R %s %s\n' "$REPO" "$PR"
  fi
} >&2
exit 2
