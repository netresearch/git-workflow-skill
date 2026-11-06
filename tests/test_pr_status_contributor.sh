#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: Netresearch DTT GmbH
# Regression test: a contributor with READ or TRIAGE access to the base
# repository can neither review into the gate, request reviewers, approve
# workflow runs, nor merge. Once their own work is done (green checks, no
# threads, no conflict), the last step is taking the PR out of draft, and
# after that NEXT hands the PR over to the maintainers.
#
# Measured on FriendsOfTYPO3/fractor#443: viewerPermission READ, fork PR,
# checks green, Copilot quota wall armed. NEXT said request-review and told
# the author to review the diff themselves and merge with
# pr-merge.sh --self-reviewed.
#
# Runs pr-status.sh against a stubbed `gh`, so it needs no network and no repo.

set -euo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/skills/git-workflow/scripts/pr-status.sh"
STUB_DIR="$(mktemp -d)"
trap 'rm -rf "$STUB_DIR"' EXIT

fail=0
check_contains() { # check_contains <name> <needle> <haystack>
    local label=$1 needle=$2 haystack=$3
    case "$haystack" in
        *"$needle"*) echo "  ok   $label" ;;
        *) echo "  FAIL $label: no '$needle' in output"; fail=1 ;;
    esac
}
check_absent() { # check_absent <name> <needle> <haystack>
    local label=$1 needle=$2 haystack=$3
    case "$haystack" in
        *"$needle"*) echo "  FAIL $label: unexpected '$needle' in output"; fail=1 ;;
        *) echo "  ok   $label" ;;
    esac
}

export XDG_CACHE_HOME="$STUB_DIR/cache"
MARKER="$XDG_CACHE_HOME/pr-status/copilot-quota-exhausted-$(date -u +%Y-%m)"
arm_marker() {
    mkdir -p "$(dirname "$MARKER")"
    printf 'copilot review quota exhausted; proven on o/r#1 at 2026-01-01T00:00:00Z\n' > "$MARKER"
}

# PERM: viewerPermission ("" leaves the field out); DRAFT: 1 for a draft;
# CHECK: COMPLETED or IN_PROGRESS; THREADS: unresolved thread count;
# MERGE_STATE: mergeStateStatus.
make_stub() {
    # REQ: comma-separated required contexts (none by default).
    python3 - "$STUB_DIR/rules.json" <<'PY2'
import json, os, sys
rules = [{"type": "copilot_code_review", "parameters": {}}]
req = [c for c in os.environ.get("REQ", "").split(",") if c]
if req:
    rules.append({"type": "required_status_checks",
                  "parameters": {"required_status_checks": [{"context": c} for c in req]}})
json.dump(rules, open(sys.argv[1], "w"))
PY2
    # RUNS_JSON: the actions/runs answer; the default holds no run awaiting approval.
    printf '%s\n' "${RUNS_JSON:-{\"workflow_runs\":[]\}}" > "$STUB_DIR/runs.json"
    cat > "$STUB_DIR/gh" <<STUB
#!/usr/bin/env bash
for a in "\$@"; do
  case "\$a" in
    repos/*/rules/branches/*) cat "$STUB_DIR/rules.json"; exit 0 ;;
    repos/*/branches/*/protection) exit 1 ;;
    repos/*/actions/runs*) cat "$STUB_DIR/runs.json"; exit 0 ;;
  esac
done
cat "$STUB_DIR/graphql.json"
STUB
    chmod +x "$STUB_DIR/gh"
    python3 - "$STUB_DIR/graphql.json" <<'PY'
import sys, json, os
out = sys.argv[1]
head = "71b534470ad2"
perm = os.environ.get("PERM", "READ")
check = os.environ.get("CHECK", "COMPLETED")
threads = int(os.environ.get("THREADS", "0"))
repo = {
    "nameWithOwner": "o/r",
    "mergeCommitAllowed": True, "rebaseMergeAllowed": True, "squashMergeAllowed": True,
}
if perm:
    repo["viewerPermission"] = perm
run = {"__typename": "CheckRun", "name": "CI", "detailsUrl": "u",
       "startedAt": "2026-01-01T00:00:00Z", "status": check,
       "conclusion": "SUCCESS" if check == "COMPLETED" else None}
def suite(status, run_id, run_number=1, workflow=None):
    workflow = workflow or 70 + run_id
    return {"status": status, "workflowRun": {
        "databaseId": run_id, "runNumber": run_number, "event": "pull_request",
        "createdAt": "2026-01-01T00:00:00Z", "url": f"run/{run_id}",
        "workflow": {"databaseId": workflow, "name": f"wf{workflow}"}}}
# STARVED_BUSY: a job that never got a runner while another job of its run
# still goes (no pending row; only the check suite says the run is busy).
# STARVED_DONE: the same job, its run concluded. STARVED_MIX: STARVED_DONE
# beside a check of another run that is still running.
nodes = [run]
if check.startswith("STARVED_"):
    run.update({"status": "COMPLETED", "conclusion": "FAILURE", "steps": {"totalCount": 0},
                "annotations": {"nodes": [{"message":
                    "The job was not started because it repeatedly failed to be acquired (5 attempts)."}]},
                "checkSuite": suite("IN_PROGRESS" if check == "STARVED_BUSY" else "COMPLETED", 7)})
# STALE: "CI" reported only by run #1 of its workflow, while the newer,
# completed run #2 of the same workflow carries no row of that name.
if check == "STALE":
    run.update({"status": "COMPLETED", "conclusion": "SUCCESS",
                "checkSuite": suite("COMPLETED", 7, 1, 70)})
    nodes.append({"__typename": "CheckRun", "name": "Other", "detailsUrl": "u3",
                  "startedAt": "2026-01-01T00:00:00Z", "status": "COMPLETED",
                  "conclusion": "SUCCESS", "checkSuite": suite("COMPLETED", 9, 2, 70)})
if check == "STARVED_MIX":
    nodes.append({"__typename": "CheckRun", "name": "Lint", "detailsUrl": "u2",
                  "startedAt": "2026-01-01T00:00:00Z", "status": "IN_PROGRESS",
                  "conclusion": None, "steps": {"totalCount": 2}, "checkSuite": suite("IN_PROGRESS", 8)})
# REVIEW: CR (changes requested on the head), CR_OLD (on an older head),
# CR_APPROVED (on the head, then approved by the same reviewer).
def review(state, oid):
    return {"author": {"login": "maint"}, "state": state, "commit": {"oid": oid}, "body": "please change"}
reviews = {
    "CR": [review("CHANGES_REQUESTED", head)],
    "CR_OLD": [review("CHANGES_REQUESTED", "0123456789ab")],
    "CR_APPROVED": [review("CHANGES_REQUESTED", head), review("APPROVED", head)],
}.get(os.environ.get("REVIEW", ""), [])
repo["pullRequest"] = {
    "number": 1, "title": "t", "state": "OPEN", "isDraft": os.environ.get("DRAFT") == "1",
    "mergeable": "MERGEABLE", "mergeStateStatus": os.environ.get("MERGE_STATE", "BLOCKED"),
    "reviewDecision": os.environ.get("DECISION") or None,
    "author": {"login": "contrib", "__typename": "User"},
    "baseRefName": "main", "headRefName": "f", "headRefOid": head,
    "isCrossRepository": True,
    "comments": {"nodes": []},
    "reviews": {"nodes": reviews},
    "reviewRequests": {"nodes": []},
    "reviewThreads": {"nodes": [
        {"id": f"T{n}", "isResolved": False, "isOutdated": False,
         "comments": {"nodes": [{"databaseId": n, "author": {"login": "maint"}, "path": "a.php"}]}}
        for n in range(threads)]},
    "commits": {"nodes": [{"commit": {"oid": head, "statusCheckRollup": {
        "state": "SUCCESS" if check == "COMPLETED" else "PENDING",
        "contexts": {"pageInfo": {"hasNextPage": False}, "nodes": nodes}}}}]},
    "allCommits": {"totalCount": 1, "nodes": [
        {"commit": {"oid": head, "signature": {"isValid": True},
                    "parents": {"totalCount": 1},
                    "authors": {"totalCount": 1, "nodes": [{"user": {"login": "contrib"}}]}}}]},
}
json.dump({"data": {"viewer": {"login": "contrib"}, "repository": repo}}, open(out, "w"))
PY
}

status() { PATH="$STUB_DIR:$PATH" bash "$SCRIPT" -R o/r 1 "$@"; }

# The case this test exists for, copied from fractor#443.
echo "case: READ, ready PR, green, quota wall -> handed-over, no self-review or merge advice"
PERM=READ make_stub; arm_marker
out=$(status)
check_contains "handed over"            "NEXT: handed-over"        "$out"
check_contains "permission named"       "you have READ access"     "$out"
check_absent   "no self-review advice"  "--self-reviewed"          "$out"
check_absent   "no approve advice"      "--approve"                "$out"
check_absent   "no review request"      "requested_reviewers"      "$out"

echo "case: READ, CLEAN -> handed-over, never merge"
PERM=READ MERGE_STATE=CLEAN make_stub; rm -f "$MARKER"
out=$(status)
check_contains "handed over"            "NEXT: handed-over"        "$out"
check_absent   "no merge"               "NEXT: merge"              "$out"

echo "case: TRIAGE -> handed-over"
PERM=TRIAGE make_stub; rm -f "$MARKER"
out=$(status)
check_contains "handed over"            "NEXT: handed-over"        "$out"

# Approving the runs needs write access, so a contributor is told they wait,
# never handed the approve call.
echo "case: READ, fork runs await approval -> handed-over names them, no approve call"
PERM=READ RUNS_JSON='{"workflow_runs":[{"id":7,"name":"Tests","status":"action_required","conclusion":null}]}' make_stub; rm -f "$MARKER"
out=$(status)
check_contains "handed over"            "NEXT: handed-over"        "$out"
check_contains "waiting runs named"     "await their approval (Tests)" "$out"
check_absent   "no approve call"        "actions/runs/7/approve"   "$out"

# Taking the PR out of draft is the contributor's last step.
echo "case: READ, settled draft -> ready, named as the last step"
PERM=READ DRAFT=1 make_stub; rm -f "$MARKER"
out=$(status)
check_contains "ready"                  "NEXT: ready"              "$out"
check_contains "last step named"        "This is your last step"   "$out"

# The contributor's own work still comes first.
echo "case: READ, unresolved thread -> resolve-threads"
PERM=READ THREADS=1 make_stub; rm -f "$MARKER"
out=$(status)
check_contains "thread first"           "NEXT: resolve-threads"    "$out"

# A review that requests changes without a thread is still the
# contributor's work, but only while it applies to the current head.
echo "case: READ, changes requested on the head, no thread -> address-comments"
PERM=READ REVIEW=CR make_stub; rm -f "$MARKER"
out=$(status)
check_contains "address the review"     "NEXT: address-comments"   "$out"
check_contains "names the reviewer"     "changes requested on 71b53447 by maint" "$out"

echo "case: READ, changes requested on an older head -> handed-over"
PERM=READ REVIEW=CR_OLD make_stub; rm -f "$MARKER"
out=$(status)
check_contains "handed over"            "NEXT: handed-over"        "$out"

echo "case: READ, changes requested, then approved by the same reviewer -> handed-over"
PERM=READ REVIEW=CR_APPROVED make_stub; rm -f "$MARKER"
out=$(status)
check_contains "handed over"            "NEXT: handed-over"        "$out"

echo "case: READ, check running -> wait, and --watch does not return"
PERM=READ CHECK=IN_PROGRESS make_stub; rm -f "$MARKER"
out=$(status)
check_contains "wait"                   "NEXT: wait"               "$out"
out=$(status --watch --interval 1 --max-wait 2 2>&1 || true)
check_absent   "watch holds"            "ACTIONABLE"               "$out"

echo "case: READ, no check running but a run still going -> wait, without a count of zero"
PERM=READ CHECK=STARVED_BUSY make_stub; rm -f "$MARKER"
out=$(status)
check_contains "wait"                   "NEXT: wait"               "$out"
check_contains "names the busy run"     "a run is still going"     "$out"
check_absent   "no zero count"          "0 check(s) still running" "$out"

# Re-running a run needs write access, so a contributor is never handed
# the command, neither as rerun-ci nor in the note appended to a wait.
echo "case: READ, a job never got a runner, its run concluded -> handed-over names it, no rerun"
PERM=READ CHECK=STARVED_DONE make_stub; rm -f "$MARKER"
out=$(status)
check_contains "handed over"            "NEXT: handed-over"        "$out"
check_contains "names the run"          "need a maintainer to re-run run(s) 7" "$out"
check_absent   "no rerun command"       "gh run rerun"             "$out"

echo "case: READ, that run beside a running check -> wait without a rerun command"
PERM=READ CHECK=STARVED_MIX make_stub; rm -f "$MARKER"
out=$(status)
check_contains "wait"                   "NEXT: wait"               "$out"
check_contains "names the run"          "run(s) 7 need a maintainer to re-run them" "$out"
check_absent   "no rerun command"       "gh run rerun"             "$out"

# What only a maintainer can clear is still named, so the contributor
# can pass it on.
echo "case: READ, a required context never reported -> handed-over names it"
PERM=READ REQ="ci / Never" make_stub; rm -f "$MARKER"
out=$(status)
check_contains "handed over"            "NEXT: handed-over"        "$out"
check_contains "names the context"      "required context(s) never reported: ci / Never" "$out"

echo "case: READ, a required context only in a superseded run -> handed-over names it"
PERM=READ REQ="CI" CHECK=STALE make_stub; rm -f "$MARKER"
out=$(status)
check_contains "handed over"            "NEXT: handed-over"        "$out"
check_contains "names the context"      "reported only by a superseded workflow run: CI" "$out"

echo "case: READ, approved but BLOCKED with no visible cause -> handed-over asks for an investigation"
PERM=READ DECISION=APPROVED make_stub; rm -f "$MARKER"
out=$(status)
check_contains "handed over"            "NEXT: handed-over"        "$out"
check_contains "says undetermined"      "BLOCKED although approved, and no cause is visible" "$out"

echo "case: READ, not yet approved -> handed-over without that claim"
PERM=READ make_stub; rm -f "$MARKER"
out=$(status)
check_absent   "no undetermined claim"  "BLOCKED although approved" "$out"

echo "case: WRITE, the same superseded run -> not handed over"
PERM=WRITE REQ="CI" CHECK=STALE make_stub; rm -f "$MARKER"
out=$(status)
check_absent   "not handed over"        "handed-over"              "$out"

echo "case: WRITE, the same concluded run -> rerun-ci as before"
PERM=WRITE CHECK=STARVED_DONE make_stub; rm -f "$MARKER"
out=$(status)
check_contains "rerun-ci"               "NEXT: rerun-ci"           "$out"

echo "case: READ, green -> --watch returns on handed-over"
PERM=READ make_stub; rm -f "$MARKER"
out=$(status --watch --interval 1 --max-wait 5 2>&1 || true)
check_contains "watch returns"          "ACTIONABLE: handed-over"  "$out"

# The advice for those who can review and merge stays as it was.
echo "case: WRITE -> request-review as before"
PERM=WRITE make_stub; arm_marker
out=$(status)
check_contains "request-review"         "NEXT: request-review"     "$out"
check_absent   "not handed over"        "handed-over"              "$out"

echo "case: permission absent -> request-review as before"
PERM="" make_stub; arm_marker
out=$(status)
check_contains "request-review"         "NEXT: request-review"     "$out"
check_absent   "not handed over"        "handed-over"              "$out"

exit "$fail"
