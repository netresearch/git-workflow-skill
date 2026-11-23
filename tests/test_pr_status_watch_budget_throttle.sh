#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: Netresearch DTT GmbH
# --watch must slow down while the GraphQL budget runs low, before it is spent.
# One gate read costs about 4 points (measured 2026-11-23), and every session
# of the same user shares one budget of 5000 points per hour, so several
# watchers polling every 20 s drain it for everything else. Below the low-water
# mark the watch waits PR_STATUS_BUDGET_LOW_WAIT seconds (default 180) between
# reads instead of --interval and says so in one pr-status: line.
#
# Runs pr-status.sh against a stubbed gh, so it needs no network and no repo.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/skills/git-workflow/scripts/pr-status.sh"
STUB_DIR="$(mktemp -d)"
trap 'rm -rf "$STUB_DIR"' EXIT
export XDG_CACHE_HOME="$STUB_DIR/cache"
# The cases set the budget variables themselves; an exported value from the
# caller's shell would change what they measure.
unset PR_STATUS_BUDGET_LOW_WATER PR_STATUS_BUDGET_LOW_WAIT LOOKUP_DELAY
export CALLS="$STUB_DIR/calls.log"

fail=0
check() {
  local label=$1 want=$2 got=$3
  if [[ "$got" == "$want" ]]; then echo "  ok   $label"
  else echo "  FAIL $label: got '$got', expected '$want'"; fail=1; fi
}
check_contains() {
  local label=$1 needle=$2 haystack=$3
  if [[ "$haystack" == *"$needle"* ]]; then echo "  ok   $label"
  else echo "  FAIL $label: '$needle' not in output:"; printf '%s\n' "$haystack" | sed 's/^/       /'; fail=1; fi
}
check_absent() {
  local label=$1 needle=$2 haystack=$3
  if [[ "$haystack" != *"$needle"* ]]; then echo "  ok   $label"
  else echo "  FAIL $label: '$needle' unexpectedly in output:"; printf '%s\n' "$haystack" | sed 's/^/       /'; fail=1; fi
}

# The stub answers rate_limit with what its --jq filter would print
# ("$REMAINING $LIMIT $RESET"), the branch rules with an empty list, and every
# other call with one PR that sits in the merge queue: NEXT is wait, so the
# watch never returns on its own. Every call is logged with its epoch second;
# a gate read is the main query, the one carrying pr=.
cat > "$STUB_DIR/gh" <<'STUB'
#!/usr/bin/env bash
echo "$(date +%s) $*" >> "$CALLS"
for a in "$@"; do
  case "$a" in
    rate_limit) sleep "${LOOKUP_DELAY:-0}"; echo "$REMAINING $LIMIT $RESET"; exit 0 ;;
    repos/*/rules/branches/*) echo '[]'; exit 0 ;;
  esac
done
cat "$FIXTURE"
STUB
chmod +x "$STUB_DIR/gh"
export FIXTURE="$STUB_DIR/queued.json"

python3 - "$FIXTURE" <<'PY'
import sys, json, datetime
now = datetime.datetime.now(datetime.timezone.utc)
enq = (now - datetime.timedelta(minutes=1)).strftime("%Y-%m-%dT%H:%M:%SZ")
head = "deadbeefcafe"
entry = {"state": "AWAITING_CHECKS", "position": 1, "estimatedTimeToMerge": None,
         "enqueuedAt": enq, "headCommit": {"oid": "e16d08a3e53d275231b38e635841b847d9b3fbc6"}}
doc = {"data": {"viewer": {"login": "someone"}, "repository": {
    "nameWithOwner": "o/r",
    "mergeCommitAllowed": True, "rebaseMergeAllowed": False, "squashMergeAllowed": False,
    "autoMergeAllowed": True,
    "pullRequest": {
        "id": "PR_kwTEST13", "number": 13, "title": "t", "state": "OPEN", "isDraft": False,
        "mergeQueue": {"id": "MQ_x"},
        "mergeable": "MERGEABLE", "mergeStateStatus": "CLEAN",
        "reviewDecision": "APPROVED",
        "mergeQueueEntry": entry,
        "author": {"login": "someone", "__typename": "User"},
        "baseRefName": "main", "headRefName": "f", "headRefOid": head,
        "isCrossRepository": False,
        "comments": {"nodes": []},
        "reviews": {"nodes": [{"author": {"login": "reviewer"}, "state": "APPROVED",
                               "commit": {"oid": head}, "body": ""}]},
        "reviewRequests": {"nodes": []},
        "reviewThreads": {"nodes": []},
        "commits": {"nodes": [{"commit": {"oid": head, "statusCheckRollup": {
            "state": "SUCCESS", "contexts": {"pageInfo": {"hasNextPage": False}, "nodes": [
                {"__typename": "CheckRun", "name": "CI", "conclusion": "SUCCESS",
                 "status": "COMPLETED", "detailsUrl": "u",
                 "startedAt": "2026-01-01T00:00:00Z"}]}}}}]},
        "allCommits": {"nodes": [{"commit": {"oid": head, "signature": {"isValid": True}}}]},
    }}}}
json.dump(doc, open(sys.argv[1], "w"))
PY

reads() { grep -c ' pr=' "$CALLS" || true; }
lookups() { grep -c ' api rate_limit' "$CALLS" || true; }
watch() { PATH="$STUB_DIR:$PATH" bash "$SCRIPT" -R o/r 13 --watch --interval 1 "$@" 2>&1; }

echo "pr-status.sh --watch: slowing down on a low GraphQL budget"

echo "case: control — the fixture is a steady wait"
: > "$CALLS"
REMAINING=4000; LIMIT=5000; RESET=$(( $(date +%s) + 1800 )); export REMAINING LIMIT RESET
check "NEXT is wait" "wait" \
  "$(PATH="$STUB_DIR:$PATH" bash "$SCRIPT" -R o/r 13 --json | jq -r '.next.action')"

echo "case: budget low — waits the longer wait, says so once"
: > "$CALLS"
REMAINING=200; LIMIT=5000; RESET=$(( $(date +%s) + 1800 )); export REMAINING LIMIT RESET
rc=0; out=$(PR_STATUS_BUDGET_LOW_WAIT=3 watch --max-wait 8) || rc=$?
check          "times out (exit 1)"              "1" "$rc"
check_contains "names remaining, limit and wait" "pr-status: GraphQL budget low — 200 of 5000 points left" "$out"
check_contains "names the new wait"              "waiting 3s between reads instead of 1s" "$out"
check          "one budget line for the whole low period" "1" \
  "$(grep -c '^pr-status: GraphQL budget low' <<<"$out" || true)"
# A read every 3 s over 8 s is three or four reads; the 1 s interval makes
# eight or more.
n=$(reads)
check "few gate reads (got $n)"                  "true" "$([ "$n" -ge 2 ] && [ "$n" -le 4 ] && echo true || echo false)"
check "looked the budget up"                     "true" "$([ "$(lookups)" -ge 1 ] && echo true || echo false)"

echo "case: budget low, default wait — capped at --max-wait"
: > "$CALLS"
start=$(date +%s)
rc=0; out=$(watch --max-wait 4) || rc=$?
took=$(( $(date +%s) - start ))
check_contains "names the default 180s wait"     "waiting 180s between reads" "$out"
check_contains "times out"                       "TIMEOUT after 4s" "$out"
check "stays within --max-wait (took ${took}s)" "true" "$([ "$took" -le 7 ] && echo true || echo false)"
check "one or two gate reads"                    "true" "$([ "$(reads)" -le 2 ] && echo true || echo false)"

echo "case: budget low, the lookup uses up --max-wait — TIMEOUT, no extra read"
: > "$CALLS"
rc=0; out=$(LOOKUP_DELAY=3 PR_STATUS_BUDGET_LOW_WAIT=3 watch --max-wait 2) || rc=$?
check          "times out (exit 1)"              "1" "$rc"
check_contains "says TIMEOUT"                    "TIMEOUT after 2s" "$out"
check          "one gate read"                   "1" "$(reads)"

echo "case: budget high — keeps the interval"
: > "$CALLS"
REMAINING=4000; LIMIT=5000; RESET=$(( $(date +%s) + 1800 )); export REMAINING LIMIT RESET
rc=0; out=$(PR_STATUS_BUDGET_LOW_WAIT=3 watch --max-wait 5) || rc=$?
check          "times out (exit 1)"              "1" "$rc"
check_absent   "no budget line"                  "GraphQL budget low" "$out"
n=$(reads)
check "a read every interval (got $n)"           "true" "$([ "$n" -ge 4 ] && echo true || echo false)"
# Without the lookup this control would pass on the unchanged script too.
check "looked the budget up"                     "true" "$([ "$(lookups)" -ge 1 ] && echo true || echo false)"

echo "case: rate_limit unreadable — keeps the interval, prints nothing"
: > "$CALLS"
REMAINING=null; LIMIT=null; RESET=null; export REMAINING LIMIT RESET
rc=0; out=$(PR_STATUS_BUDGET_LOW_WAIT=3 watch --max-wait 5) || rc=$?
check_absent   "no budget line"                  "GraphQL budget" "$out"
n=$(reads)
check "a read every interval (got $n)"           "true" "$([ "$n" -ge 4 ] && echo true || echo false)"

echo "case: low-water mark set lower — 200 left is not low"
: > "$CALLS"
REMAINING=200; LIMIT=5000; RESET=$(( $(date +%s) + 1800 )); export REMAINING LIMIT RESET
rc=0; out=$(PR_STATUS_BUDGET_LOW_WATER=100 PR_STATUS_BUDGET_LOW_WAIT=3 watch --max-wait 5) || rc=$?
check_absent   "no budget line"                  "GraphQL budget low" "$out"
n=$(reads)
check "a read every interval (got $n)"           "true" "$([ "$n" -ge 4 ] && echo true || echo false)"

exit "$fail"
