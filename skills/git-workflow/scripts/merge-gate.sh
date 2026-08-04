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

# Parse the PR id from the three `gh pr merge` reference forms.
PR=""; REPO_FLAG=()
if [[ "$CMD" =~ gh[[:space:]]+pr[[:space:]]+merge[[:space:]]+(--[a-z-]+([[:space:]]+[^[:space:]]+)?[[:space:]]+)*([0-9]+)([[:space:]]|$) ]]; then
  PR="${BASH_REMATCH[3]}"
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
URL=$(echo "$INFO" | jq -r '.url // ""')
[[ "$URL" =~ github\.com/([^/]+)/([^/]+)/pull/([0-9]+) ]] || exit 0
O="${BASH_REMATCH[1]}"; RN="${BASH_REMATCH[2]}"; NUM="${BASH_REMATCH[3]}"
UNRES=$(gh api graphql -f query="{repository(owner:\"$O\",name:\"$RN\"){pullRequest(number:$NUM){reviewThreads(first:100){nodes{isResolved}}}}}" \
  --jq '[.data.repository.pullRequest.reviewThreads.nodes[]? | select(.isResolved==false)] | length' 2>/dev/null) || UNRES=0

if [[ "${UNRES:-0}" -gt 0 || "$MSS" != "CLEAN" ]]; then
  jq -cn --arg r "merge-gate: unresolved-threads=$UNRES, mergeState=$MSS — resolve threads / clear the block (check the ruleset & thread state) before merging" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}'
fi
