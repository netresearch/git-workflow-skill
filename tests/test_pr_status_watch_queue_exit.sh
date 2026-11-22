#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: Netresearch DTT GmbH
# --watch must not return `merge` on the read where a queued PR has just left
# the merge queue but still reads OPEN. Observed on
# netresearch/typo3-ai-edition#13 (2026-11-22): four `waiting: already in the
# merge queue at position 1 (AWAITING_CHECKS)` polls, then `ACTIONABLE: merge`
# with `state: OPEN mergeable=MERGEABLE mergeState=CLEAN`; the queue merged the
# PR at 21:09:12Z, and the timeline records no drop before the merge.
#
# The stub serves one GraphQL fixture per poll from a phase list and advances
# only on the main PR query (the one carrying `pr=`), so each poll sees exactly
# one phase; every advance is logged and the consumed sequence is asserted.
#
# Runs against a stubbed `gh`, so it needs no network and no repository.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/skills/git-workflow/scripts/pr-status.sh"
STUB_DIR="$(mktemp -d)"
trap 'rm -rf "$STUB_DIR"' EXIT
export XDG_CACHE_HOME="$STUB_DIR/cache"

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

# The phase of the current poll is the last line of $STUB_DIR/served; a main
# query appends the next phase from $STUB_DIR/phases (the last one repeats).
cat > "$STUB_DIR/gh" <<STUB
#!/usr/bin/env bash
main=0
for a in "\$@"; do
  case "\$a" in
    repos/*/rules/branches/*) echo '[]'; exit 0 ;;
    pr=*) main=1 ;;
  esac
done
if [ "\$main" = "1" ]; then
  n=\$(( \$(wc -l < "$STUB_DIR/served") + 1 ))
  total=\$(wc -l < "$STUB_DIR/phases")
  [ "\$n" -le "\$total" ] || n=\$total
  sed -n "\${n}p" "$STUB_DIR/phases" >> "$STUB_DIR/served"
fi
cat "$STUB_DIR/\$(tail -n 1 "$STUB_DIR/served").json"
STUB
chmod +x "$STUB_DIR/gh"

# Three fixtures: queued (AWAITING_CHECKS, enqueued a minute ago, so the
# stuck-entry runs read is skipped), open (no entry, OPEN, CLEAN) and merged.
python3 - "$STUB_DIR" <<'PY'
import sys, json, datetime
d = sys.argv[1]
now = datetime.datetime.now(datetime.timezone.utc)
enq = (now - datetime.timedelta(minutes=1)).strftime("%Y-%m-%dT%H:%M:%SZ")
head = "deadbeefcafe"
def pr(state, entry):
    return {"data": {"viewer": {"login": "someone"}, "repository": {
        "nameWithOwner": "o/r",
        "mergeCommitAllowed": True, "rebaseMergeAllowed": False, "squashMergeAllowed": False,
        "autoMergeAllowed": True,
        "pullRequest": {
            "id": "PR_kwTEST13", "number": 13, "title": "t", "state": state, "isDraft": False,
            "mergeQueue": {"id": "MQ_x"},
            "mergeable": "MERGEABLE" if state == "OPEN" else "UNKNOWN",
            "mergeStateStatus": "CLEAN" if state == "OPEN" else "UNKNOWN",
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
entry = {"state": "AWAITING_CHECKS", "position": 1, "estimatedTimeToMerge": None,
         "enqueuedAt": enq, "headCommit": {"oid": "e16d08a3e53d275231b38e635841b847d9b3fbc6"}}
json.dump(pr("OPEN", entry), open(d + "/queued.json", "w"))
json.dump(pr("OPEN", None), open(d + "/open.json", "w"))
json.dump(pr("MERGED", None), open(d + "/merged.json", "w"))
PY

# phases <phase>... — the sequence the polls will see, reset per case.
phases() { printf '%s\n' "$@" > "$STUB_DIR/phases"; : > "$STUB_DIR/served"; }
served() { paste -sd' ' "$STUB_DIR/served"; }
watch() { PATH="$STUB_DIR:$PATH" bash "$SCRIPT" -R o/r 13 --watch --interval 1 "$@"; }

echo "pr-status.sh --watch: a queued PR leaving the merge queue"

echo "case: control — the open fixture alone is merge-ready"
phases open
check "NEXT on the open read is merge" "merge" \
  "$(PATH="$STUB_DIR:$PATH" bash "$SCRIPT" -R o/r 13 --json | jq -r '.next.action')"

echo "case: queued -> open -> open -> merged: holds, returns on the merged read"
phases queued open open merged
rc=0; out=$(watch --max-wait 30 2>&1) || rc=$?
check          "exits 0"                         "0" "$rc"
check_absent   "no ACTIONABLE: merge"            "ACTIONABLE: merge" "$out"
check_contains "the hold says why"               "left the merge queue" "$out"
check_contains "returns on the merged read"      "ACTIONABLE: none" "$out"
check_contains "the returned state is MERGED"    "MERGED" "$out"
check          "polls saw each phase once"       "queued open open merged" "$(served)"

echo "case: queued -> open -> queued: back in the queue, keeps waiting"
phases queued open queued
rc=0; out=$(watch --max-wait 4 2>&1) || rc=$?
check          "times out (exit 1)"              "1" "$rc"
check_absent   "no ACTIONABLE return"            "ACTIONABLE" "$out"
check_contains "waits on the queue again"        "already in the merge queue" "$out"
check_contains "the polls went through open and back" "queued open queued" "$(served)"

echo "case: queued -> open past the bound: returns, and says the queue did not merge it"
phases queued open
rc=0; out=$(PR_STATUS_QUEUE_EXIT_GRACE=2 watch --max-wait 30 2>&1) || rc=$?
check          "exits 0"                         "0" "$rc"
check_contains "returns merge after the bound"   "ACTIONABLE: merge" "$out"
check_contains "with the caveat line"            "pr-status: o/r#13 left the merge queue" "$out"
check_contains "the caveat points at the timeline" "confirm the drop on the timeline" "$out"
check_contains "the caveat survives the Monitor filter" "pr-status: o/r#13 left the merge queue" \
  "$(grep -vE '^waiting' <<<"$out" | grep -E '^(ACTIONABLE|TIMEOUT|SETTLED|NEXT)|^\s*(failing|checks)|pr-status:' || true)"
check_contains "it held at least one poll first" "queued open open" "$(served)"

echo "case: queued -> open, --max-wait shorter than the bound: TIMEOUT says not merged"
phases queued open
rc=0; out=$(watch --max-wait 2 2>&1) || rc=$?
check          "exits 1"                         "1" "$rc"
check_contains "TIMEOUT names the state"         "left the merge queue and still reads OPEN" "$out"
check_absent   "no ACTIONABLE return"            "ACTIONABLE" "$out"

echo "case: never seen queued, OPEN and CLEAN: returns merge at once"
phases open
rc=0; out=$(watch --max-wait 30 2>&1) || rc=$?
check          "exits 0"                         "0" "$rc"
check_contains "returns merge"                   "ACTIONABLE: merge" "$out"
check_absent   "no hold"                         "left the merge queue" "$out"
check          "one poll"                        "open" "$(served)"

exit "$fail"
