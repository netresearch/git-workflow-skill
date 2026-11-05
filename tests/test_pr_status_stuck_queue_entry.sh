#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: Netresearch DTT GmbH
# A merge-queue entry can stay in AWAITING_CHECKS although every merge_group
# run of its queue commit has completed green. Measured on
# netresearch/t3x-nr-image-optimize#238 (2026-11-04): enqueued 10:55:24Z, the
# three queue runs green by 10:59:14Z, the entry unchanged until 12:11, and
# `pr-status.sh --watch` heartbeated "already in the merge queue" into its
# TIMEOUT. One dequeue + enqueue merged it.
#
# NEXT names stuck-queue-entry only when ALL of these hold: the entry is in
# AWAITING_CHECKS, at least one merge_group run exists for the queue commit,
# none is queued or running, all concluded green, and the last one completed at
# least --stuck-after minutes ago. Every other shape stays `wait`. The runs
# endpoint is asked only once the entry is older than the threshold, which is
# asserted through a marker the stub writes.
#
# Runs against a stubbed `gh`, so it needs no network and no repository.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/skills/git-workflow/scripts/pr-status.sh"
STUB_DIR="$(mktemp -d)"
trap 'rm -rf "$STUB_DIR"' EXIT

fail=0
QHEAD="e16d08a3e53d275231b38e635841b847d9b3fbc6"

cat > "$STUB_DIR/gh" <<STUB
#!/usr/bin/env bash
for a in "\$@"; do
  case "\$a" in
    repos/*/rules/branches/*) echo '[]'; exit 0 ;;
    repos/*/actions/runs\?event=merge_group*)
      echo "\$*" >> "$STUB_DIR/runs-called"
      cat "$STUB_DIR/runs.json"; exit 0 ;;
  esac
done
cat "$STUB_DIR/graphql.json"
STUB
chmod +x "$STUB_DIR/gh"

# fixture <entry-state> <enqueued N min ago> <runs spec>
# runs spec: comma-separated name:status:conclusion:updated-N-min-ago, or "none"
fixture() {
  local entry_state=$1 enqueued_min=$2 runs_spec=$3
  rm -f "$STUB_DIR/runs-called"
  python3 - "$STUB_DIR" "$entry_state" "$enqueued_min" "$runs_spec" "$QHEAD" <<'PY'
import sys, json, datetime
d, state, enq, spec, qhead = sys.argv[1:6]
now = datetime.datetime.now(datetime.timezone.utc)
ago = lambda m: (now - datetime.timedelta(minutes=int(m))).strftime("%Y-%m-%dT%H:%M:%SZ")
runs = []
if spec != "none":
    for r in spec.split(","):
        name, status, concl, upd = r.split(":")
        runs.append({"name": name, "status": status,
                     "conclusion": None if concl == "-" else concl,
                     "head_sha": qhead, "event": "merge_group",
                     "head_branch": "gh-readonly-queue/main/pr-238-d7c7e417",
                     "updated_at": ago(upd)})
json.dump({"total_count": len(runs), "workflow_runs": runs}, open(d + "/runs.json", "w"))
head = "deadbeefcafe"
json.dump({"data": {"viewer": {"login": "someone"}, "repository": {
    "nameWithOwner": "o/r",
    "mergeCommitAllowed": True, "rebaseMergeAllowed": False, "squashMergeAllowed": False,
    "autoMergeAllowed": True,
    "pullRequest": {
        "id": "PR_kwTEST238", "number": 238, "title": "t", "state": "OPEN", "isDraft": False,
        "mergeQueue": {"id": "MQ_x"},
        "mergeable": "MERGEABLE", "mergeStateStatus": "CLEAN", "reviewDecision": "APPROVED",
        "mergeQueueEntry": {"state": state, "position": 1, "estimatedTimeToMerge": None,
                            "enqueuedAt": ago(enq), "headCommit": {"oid": qhead}},
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
    }}}}, open(d + "/graphql.json", "w"))
PY
}

status() { PATH="$STUB_DIR:$PATH" bash "$SCRIPT" -R o/r 238 --json "$@"; }
watch()  { PATH="$STUB_DIR:$PATH" bash "$SCRIPT" -R o/r 238 --watch --interval 1 "$@"; }

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
  else echo "  FAIL $label: '$needle' unexpectedly in output"; fail=1; fi
}
runs_called() { [[ -f "$STUB_DIR/runs-called" ]] && echo yes || echo no; }

NEXT_ACTION='.next.action'
STUCK='stuck-queue-entry'
# next_action [status args…] — the NEXT action of one pr-status.sh --json run.
next_action() { status "$@" | jq -r "$NEXT_ACTION"; }
expect_wait() { check "NEXT is wait" "wait" "$(next_action)"; }

GREEN3="CI:completed:success:80,Checks:completed:success:82,Template Drift:completed:success:84"

echo "pr-status.sh: merge-queue entry stuck in AWAITING_CHECKS"

echo "case: all queue runs green 80 min ago, entry still AWAITING_CHECKS -> stuck-queue-entry"
fixture AWAITING_CHECKS 85 "$GREEN3"
out=$(status)
check          "NEXT is stuck-queue-entry" "$STUCK" "$(jq -r "$NEXT_ACTION" <<<"$out")"
check_contains "the cmd dequeues the PR"   "dequeuePullRequest(input:{id:\$id})" "$(jq -r '.next.cmd' <<<"$out")"
check_contains "the cmd enqueues it again" "enqueuePullRequest(input:{pullRequestId:\$id})" "$(jq -r '.next.cmd' <<<"$out")"
check_contains "the cmd names the PR node id" "id=PR_kwTEST238" "$(jq -r '.next.cmd' <<<"$out")"
check_contains "the why says the cause is not determined" "cause not determined" "$(jq -r '.next.why' <<<"$out")"
check          "the queue commit is reported" "$QHEAD" "$(jq -r '.queue_entry.head_oid' <<<"$out")"
check          "the runs are reported" "3" "$(jq -r '.queue_entry.runs.total' <<<"$out")"
check          "the runs endpoint was read by head_sha" "yes" \
               "$(grep -q "head_sha=$QHEAD" "$STUB_DIR/runs-called" && echo yes || echo no)"
rc=0; wout=$(watch --max-wait 4) || rc=$?
check          "--watch exits 0"            "0" "$rc"
check_contains "--watch returns ACTIONABLE" "ACTIONABLE: stuck-queue-entry" "$wout"
# The documented Monitor filter must keep the line.
check_contains "the Monitor filter keeps it" "ACTIONABLE: stuck-queue-entry" \
  "$(grep -vE '^waiting' <<<"$wout" | grep -E '^(ACTIONABLE|TIMEOUT|SETTLED|NEXT)|^\s*(failing|checks)|pr-status:' || true)"
rc=0; PATH="$STUB_DIR:$PATH" bash "$SCRIPT" -R o/r 238 --watch --interval 1 --max-wait 2 \
  --ignore-action stuck-queue-entry >/dev/null 2>&1 || rc=$?
check          "--ignore-action accepts it (no exit 2)" "yes" "$([[ "$rc" != "2" ]] && echo yes || echo no)"

echo "case: one queue run still in progress -> wait"
fixture AWAITING_CHECKS 85 "CI:in_progress:-:1,Checks:completed:success:82"
expect_wait
rc=0; wout=$(watch --max-wait 2) || rc=$?
check          "--watch times out (exit 1)" "1" "$rc"
check_absent   "no ACTIONABLE return"       "ACTIONABLE" "$wout"

echo "case: runs green, but only 5 min ago -> wait"
fixture AWAITING_CHECKS 60 "CI:completed:success:5,Checks:completed:success:6"
expect_wait

echo "case: entry younger than the threshold -> wait, runs endpoint not read"
fixture AWAITING_CHECKS 10 "CI:completed:success:5"
expect_wait
check "runs endpoint not called" "no" "$(runs_called)"

echo "case: no merge_group run at all -> wait (vacuous 'all finished')"
fixture AWAITING_CHECKS 85 none
expect_wait

echo "case: a queue run concluded red -> wait (the queue drops that entry itself)"
fixture AWAITING_CHECKS 85 "CI:completed:failure:80,Checks:completed:success:82"
expect_wait

echo "case: entry QUEUED, not AWAITING_CHECKS -> wait, runs endpoint not read"
fixture QUEUED 85 "$GREEN3"
expect_wait
check "runs endpoint not called" "no" "$(runs_called)"

echo "case: total_count exceeds the rows read -> wait (an unread run may be unfinished)"
fixture AWAITING_CHECKS 85 "$GREEN3"
jq '.total_count = 150' "$STUB_DIR/runs.json" >"$STUB_DIR/runs.tmp" && mv "$STUB_DIR/runs.tmp" "$STUB_DIR/runs.json"
expect_wait
check "the runs are reported as not fully fetched" "false" "$(status | jq -r '.queue_entry.runs.fetched')"
check "the runs endpoint was read with --paginate" "yes" \
      "$(grep -q -- '--paginate' "$STUB_DIR/runs-called" && echo yes || echo no)"

# Two pages as `gh api --paginate` prints them: two JSON documents back to
# back, each with the full total_count. The second page holds the third run.
two_pages() {
  local last_run=$1
  fixture AWAITING_CHECKS 85 "$GREEN3"
  jq -c --arg last "$last_run" '.total_count = 3
         | (.workflow_runs[2] | .conclusion = $last) as $third
         | (.workflow_runs = .workflow_runs[0:2]), {total_count: 3, workflow_runs: [$third]}' \
     "$STUB_DIR/runs.json" >"$STUB_DIR/runs.tmp" && mv "$STUB_DIR/runs.tmp" "$STUB_DIR/runs.json"
}
echo "case: runs split over two pages, all green -> stuck-queue-entry over all three"
two_pages success
out=$(status)
check "NEXT is stuck-queue-entry" "$STUCK" "$(jq -r "$NEXT_ACTION" <<<"$out")"
check "runs from both pages are counted" "3" "$(jq -r '.queue_entry.runs.total' <<<"$out")"
echo "case: a red run only on the second page -> wait"
two_pages failure
expect_wait

echo "case: run names past the 128 KiB argument cap still evaluate"
fixture AWAITING_CHECKS 85 "$GREEN3"
python3 - "$STUB_DIR/runs.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
run = d["workflow_runs"][0]
d["workflow_runs"] = [dict(run, name=f"{i:04d}-" + "w" * 300) for i in range(500)]
d["total_count"] = len(d["workflow_runs"])
json.dump(d, open(p, "w"))
PY
check "500 runs with 300-character names -> stuck-queue-entry" "$STUCK" "$(next_action)"

echo "case: threshold from flag and environment"
fixture AWAITING_CHECKS 85 "$GREEN3"
check "--stuck-after 120 holds at wait" "wait" "$(next_action --stuck-after 120)"
check "PR_STATUS_STUCK_AFTER_MINUTES=120 holds at wait" "wait" \
      "$(PR_STATUS_STUCK_AFTER_MINUTES=120 next_action)"
check "PR_STATUS_STUCK_AFTER_MINUTES=60 fires" "$STUCK" \
      "$(PR_STATUS_STUCK_AFTER_MINUTES=60 next_action)"
check "an invalid env value falls back to 15" "$STUCK" \
      "$(PR_STATUS_STUCK_AFTER_MINUTES=abc next_action)"
rc=0; status --stuck-after 0 >/dev/null 2>&1 || rc=$?
check "--stuck-after 0 is refused (exit 2)" "2" "$rc"

exit "$fail"
