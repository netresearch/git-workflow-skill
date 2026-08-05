#!/usr/bin/env bash
# PreToolUse gate for `gh pr merge`. Reads the Claude Code hook payload on stdin
# and emits a deny if the target PR has unresolved review threads or a non-CLEAN
# merge state — the exact gap that caused repeated mis-merges/mis-diagnoses.
#
# NOTE: deliberately does NOT gate on reviewDecision. NR repos routinely have
# reviewDecision "" (no human-approval rule) and merge legitimately when CLEAN;
# mergeStateStatus==CLEAN already encodes GitHub's required-approval gate. Gating
# on reviewDecision!=APPROVED would false-positive-block every such repo.
set -euo pipefail
CMD=$(jq -r '.tool_input.command // ""')

# Parse the PR id from the three `gh pr merge` reference forms. Flags before
# the number may be long or short, with a separate or =-joined value
# (--merge, --repo owner/repo, --repo=owner/repo, -R owner/repo).
PR=""; REPO_FLAG=()
if [[ "$CMD" =~ gh[[:space:]]+pr[[:space:]]+merge[[:space:]]+((-{1,2}[A-Za-z][A-Za-z-]*(=[^[:space:]]*)?([[:space:]]+[^-][^[:space:]]*)?)[[:space:]]+)*([0-9]+)([[:space:]]|$) ]]; then
  PR="${BASH_REMATCH[5]}"
elif [[ "$CMD" =~ gh[[:space:]]+pr[[:space:]]+merge[[:space:]]+.*https?://github\.com/([^/]+/[^/]+)/pull/([0-9]+) ]]; then
  PR="${BASH_REMATCH[2]}"; REPO_FLAG=(--repo "${BASH_REMATCH[1]}")
elif [[ "$CMD" =~ gh[[:space:]]+pr[[:space:]]+merge[[:space:]]+.*([^/[:space:]]+/[^#[:space:]]+)#([0-9]+) ]]; then
  PR="${BASH_REMATCH[2]}"; REPO_FLAG=(--repo "${BASH_REMATCH[1]}")
fi
# Honor an explicit --repo/-R owner/repo if present (overrides URL/shorthand).
# Both spellings, space- or =-separated: without this the PR number was
# resolved against the CWD repo and produced false denials (2026-08-03).
if [[ "$CMD" =~ (--repo|-R)([[:space:]]+|=)([^[:space:]]+) ]]; then
  REPO_FLAG=(--repo "${BASH_REMATCH[3]}")
fi

# Could not parse a PR id — allow rather than false-positive block.
[[ -z "$PR" ]] && exit 0

# NB: `reviewThreads` is NOT a valid `gh pr view --json` field — gh errors
# "Unknown JSON field". Fetch mergeStateStatus + url here, then get thread
# resolution via GraphQL (owner/repo/number parsed from the url).
INFO=$(gh pr view "$PR" "${REPO_FLAG[@]}" --json mergeStateStatus,url 2>/dev/null) || exit 0
MSS=$(echo "$INFO" | jq -r '.mergeStateStatus // "null"')
# UNKNOWN usually means GitHub is still computing the state (fresh push, or a
# merge landed elsewhere moments ago). Re-poll briefly before evaluating, so a
# legitimate merge isn't denied on a transient; a persistent UNKNOWN still
# denies below (fail-closed). This is a bounded pre-check inside a PreToolUse
# hook, not a merge-driver loop — pr-status.sh --watch remains the watcher.
tries=0
while [[ "$MSS" == "UNKNOWN" && $tries -lt 3 ]]; do
  sleep 3
  INFO=$(gh pr view "$PR" "${REPO_FLAG[@]}" --json mergeStateStatus,url 2>/dev/null) || exit 0
  MSS=$(echo "$INFO" | jq -r '.mergeStateStatus // "null"')
  tries=$((tries + 1))
done
URL=$(echo "$INFO" | jq -r '.url // ""')
[[ "$URL" =~ github\.com/([^/]+)/([^/]+)/pull/([0-9]+) ]] || exit 0
O="${BASH_REMATCH[1]}"; RN="${BASH_REMATCH[2]}"; NUM="${BASH_REMATCH[3]}"
# Paginate the thread list — first:100 alone silently under-counts on PRs
# with more threads (a round count is a truncation smell).
UNRES=0; CURSOR=""
while :; do
  ARGS=(-F owner="$O" -F name="$RN" -F num="$NUM")
  [[ -n "$CURSOR" ]] && ARGS+=(-F cursor="$CURSOR")
  # shellcheck disable=SC2016  # $-names are GraphQL variables, not shell
  PAGE=$(gh api graphql "${ARGS[@]}" -f query='query($owner:String!,$name:String!,$num:Int!,$cursor:String){repository(owner:$owner,name:$name){pullRequest(number:$num){reviewThreads(first:100,after:$cursor){pageInfo{hasNextPage endCursor}nodes{isResolved}}}}}' 2>/dev/null) || break
  N=$(jq -r '[.data.repository.pullRequest.reviewThreads.nodes[]? | select(.isResolved==false)] | length' <<<"$PAGE" 2>/dev/null) || break
  UNRES=$((UNRES + N))
  [[ "$(jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.hasNextPage' <<<"$PAGE")" == "true" ]] || break
  CURSOR=$(jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.endCursor' <<<"$PAGE")
done

if [[ "${UNRES:-0}" -gt 0 || "$MSS" != "CLEAN" ]]; then
  jq -cn --arg r "merge-gate: unresolved-threads=$UNRES, mergeState=$MSS — resolve threads / clear the block (check the ruleset & thread state) before merging" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}'
fi
