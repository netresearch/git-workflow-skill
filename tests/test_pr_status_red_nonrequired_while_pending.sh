#!/usr/bin/env bash
# Regression test for #249: a red NON-required check must not end a --watch
# while a REQUIRED check is still running.
#
# The triage-ci branch sat above the pending-required branch, so any red check
# short-circuited to an action even with required checks in flight. Nothing was
# actionable at that point — the gate was still held by the running required
# check — and every early return cost a manual re-arm.
#
# Now triage-ci waits for the required checks to conclude, and the wait branch
# names the red non-required check instead of hiding it.
#
# Runs pr-status.sh against a stubbed `gh`, so it needs no network and no repo.

set -euo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/skills/git-workflow/scripts/pr-status.sh"
STUB_DIR="$(mktemp -d)"
trap 'rm -rf "$STUB_DIR"' EXIT

fail=0
check() { # check <name> <expected> <actual>
    if [ "$2" = "$3" ]; then
        echo "  ok   $1"
    else
        echo "  FAIL $1: expected '$2', got '$3'"
        fail=1
    fi
}
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

# Stub `gh`: "gate" is the required context.
#   GATE_STATUS=IN_PROGRESS|SUCCESS  — state of the required check
#   RED_EXTRA=1                      — adds a red non-required check
make_stub() {
    printf '%s\n' '[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"gate"}]}}]' \
        > "$STUB_DIR/rules.json"
    cat > "$STUB_DIR/gh" <<STUB
#!/usr/bin/env bash
for a in "\$@"; do
  case "\$a" in
    repos/*/rules/branches/*) cat "$STUB_DIR/rules.json"; exit 0 ;;
  esac
done
cat "$STUB_DIR/graphql.json"
STUB
    chmod +x "$STUB_DIR/gh"
    python3 - "$STUB_DIR/graphql.json" <<'PY'
import sys, json, os
out = sys.argv[1]
head = "deadbeefcafe"
gate_status = os.environ.get("GATE_STATUS", "IN_PROGRESS")
checks = [{"__typename": "CheckRun", "name": "gate",
           "conclusion": None if gate_status == "IN_PROGRESS" else gate_status,
           "status": "IN_PROGRESS" if gate_status == "IN_PROGRESS" else "COMPLETED",
           "detailsUrl": "u", "startedAt": "2026-01-01T00:00:00Z"}]
if os.environ.get("RED_EXTRA", "0") == "1":
    checks.append({"__typename": "CheckRun", "name": "codecov/project",
                   "conclusion": "FAILURE", "status": "COMPLETED",
                   "detailsUrl": "u", "startedAt": "2026-01-01T00:00:00Z"})
json.dump({"data": {"repository": {
    "nameWithOwner": "o/r",
    "mergeCommitAllowed": True, "rebaseMergeAllowed": False, "squashMergeAllowed": False,
    "pullRequest": {
        "number": 1, "title": "t", "state": "OPEN", "isDraft": False,
        "mergeable": "MERGEABLE", "mergeStateStatus": "UNSTABLE", "reviewDecision": None,
        "author": {"login": "someone"},
        "baseRefName": "main", "headRefName": "f", "headRefOid": head,
        "isCrossRepository": False,
        "reviews": {"nodes": [{"author": {"login": "rev"}, "state": "APPROVED",
                               "commit": {"oid": head}, "body": ""}]},
        "reviewRequests": {"nodes": []},
        "reviewThreads": {"nodes": []},
        "commits": {"nodes": [{"commit": {"oid": head, "statusCheckRollup": {
            "state": "FAILURE", "contexts": {"nodes": checks}}}}]},
        "allCommits": {"nodes": [{"commit": {"oid": head,
                                             "signature": {"isValid": True}}}]},
    }}}}, open(out, "w"))
PY
}

status() { PATH="$STUB_DIR:$PATH" bash "$SCRIPT" -R o/r 1 --json; }
watch() { PATH="$STUB_DIR:$PATH" bash "$SCRIPT" -R o/r 1 --json --watch "$@"; }

echo "case: required still running, non-required red -> wait, not triage-ci"
GATE_STATUS=IN_PROGRESS RED_EXTRA=1 make_stub
out=$(status)
check_absent   "no triage-ci"                  '"action": "triage-ci"' "$out"
check_contains "waits on the required check"   "required check(s) still pending: gate" "$out"
check_contains "names the red non-required"    "non-required red meanwhile: codecov/project" "$out"

echo "case: --watch holds instead of returning"
rc=0; out=$(watch --interval 1 --max-wait 2) || rc=$?
check        "exits 1 (timeout, still waiting)" "1" "$rc"
check_absent "no ACTIONABLE return"             "ACTIONABLE" "$out"

echo "case: required concluded, non-required still red -> triage-ci"
GATE_STATUS=SUCCESS RED_EXTRA=1 make_stub
out=$(status)
check_contains "returns triage-ci"        '"action": "triage-ci"' "$out"
check_contains "names the failing check"  "codecov/project" "$out"

echo "case: a red REQUIRED check still returns at once"
GATE_STATUS=FAILURE RED_EXTRA=0 make_stub
rc=0; out=$(watch --interval 1 --max-wait 4) || rc=$?
check          "exits 0"                     "0" "$rc"
check_contains "returns on the required red" "ACTIONABLE" "$out"
check_contains "names it as required"        "required check(s) failing: gate" "$out"

exit "$fail"
