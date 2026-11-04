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
    case "$3" in
        *"$2"*) echo "  ok   $1" ;;
        *) echo "  FAIL $1: no '$2' in output"; fail=1 ;;
    esac
}
check_absent() { # check_absent <name> <needle> <haystack>
    case "$3" in
        *"$2"*) echo "  FAIL $1: unexpected '$2' in output"; fail=1 ;;
        *) echo "  ok   $1" ;;
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
    printf '%s\n' '[{"type":"copilot_code_review","parameters":{}}]' > "$STUB_DIR/rules.json"
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
repo["pullRequest"] = {
    "number": 1, "title": "t", "state": "OPEN", "isDraft": os.environ.get("DRAFT") == "1",
    "mergeable": "MERGEABLE", "mergeStateStatus": os.environ.get("MERGE_STATE", "BLOCKED"),
    "reviewDecision": None,
    "author": {"login": "contrib", "__typename": "User"},
    "baseRefName": "main", "headRefName": "f", "headRefOid": head,
    "isCrossRepository": True,
    "comments": {"nodes": []},
    "reviews": {"nodes": []},
    "reviewRequests": {"nodes": []},
    "reviewThreads": {"nodes": [
        {"id": f"T{n}", "isResolved": False, "isOutdated": False,
         "comments": {"nodes": [{"databaseId": n, "author": {"login": "maint"}, "path": "a.php"}]}}
        for n in range(threads)]},
    "commits": {"nodes": [{"commit": {"oid": head, "statusCheckRollup": {
        "state": "SUCCESS" if check == "COMPLETED" else "PENDING",
        "contexts": {"pageInfo": {"hasNextPage": False}, "nodes": [run]}}}}]},
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

echo "case: READ, check running -> wait, and --watch does not return"
PERM=READ CHECK=IN_PROGRESS make_stub; rm -f "$MARKER"
out=$(status)
check_contains "wait"                   "NEXT: wait"               "$out"
out=$(status --watch --interval 1 --max-wait 2 2>&1 || true)
check_absent   "watch holds"            "ACTIONABLE"               "$out"

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
