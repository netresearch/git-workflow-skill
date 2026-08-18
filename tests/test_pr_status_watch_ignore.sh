#!/usr/bin/env bash
# Regression test for #165: --watch must be able to hold through a standing
# action the caller has consciously declined.
#
# Before the fix, `.next.action` already actionable at invocation made --watch
# return on the first poll, every time — on a quota-dead request-review the
# watch degraded into a no-op that could not wait for the still-pending
# checks. --ignore-action <action> names the declined action: the watch then
# returns only on a different actionable event, or with SETTLED (exit 0) once
# the checks settle and the ignored action is all that remains.
#
# Runs pr-status.sh against a stubbed `gh`, so it needs no network and no repo.

set -euo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/skills/git-workflow/scripts/pr-status.sh"
STUB_DIR="$(mktemp -d)"
trap 'rm -rf "$STUB_DIR"' EXIT

ERR_QUOTA="Copilot was unable to review this pull request because the user who requested the review has reached their quota limit."

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

# pr-status.sh remembers a proven quota wall under $XDG_CACHE_HOME/pr-status —
# keep that state inside the throwaway stub dir (see the sibling test).
export XDG_CACHE_HOME="$STUB_DIR/cache"
clear_marker() { rm -rf "$XDG_CACHE_HOME/pr-status"; }

# Stub `gh`: rules endpoint answers a copilot_code_review ruleset, graphql
# answers a payload with one errored (quota) Copilot review on the head.
#   PENDING_CHECK=1 make_stub — adds an IN_PROGRESS check (checks_settled false)
#   FAIL_CHECK=1 make_stub    — adds a COMPLETED/FAILURE check
#   MERGEABLE=CONFLICTING make_stub — merge conflict (NEXT: resolve-conflicts)
make_stub() {
    clear_marker
    printf '%s\n' '[{"type":"copilot_code_review","parameters":{}}]' > "$STUB_DIR/rules.json"
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
    python3 - "$STUB_DIR/graphql.json" "$ERR_QUOTA" <<'PY'
import sys, json, os
out, body = sys.argv[1], sys.argv[2]
head = "deadbeefcafe"
checks = [{"__typename": "CheckRun", "name": "CI", "conclusion": "SUCCESS",
           "status": "COMPLETED", "detailsUrl": "u",
           "startedAt": "2026-01-01T00:00:00Z"}]
if os.environ.get("PENDING_CHECK", "0") == "1":
    checks.append({"__typename": "CheckRun", "name": "slow", "conclusion": None,
                   "status": "IN_PROGRESS", "detailsUrl": "u",
                   "startedAt": "2026-01-01T00:00:00Z"})
if os.environ.get("FAIL_CHECK", "0") == "1":
    checks.append({"__typename": "CheckRun", "name": "broken", "conclusion": "FAILURE",
                   "status": "COMPLETED", "detailsUrl": "u",
                   "startedAt": "2026-01-01T00:00:00Z"})
mergeable = os.environ.get("MERGEABLE", "MERGEABLE")
reviews = [{"author": {"login": "copilot-pull-request-reviewer"},
            "state": "COMMENTED", "commit": {"oid": head}, "body": body}]
json.dump({"data": {"repository": {
    "nameWithOwner": "o/r",
    "mergeCommitAllowed": True, "rebaseMergeAllowed": False, "squashMergeAllowed": False,
    "pullRequest": {
        "number": 1, "title": "t", "state": "OPEN", "isDraft": False,
        "mergeable": mergeable, "mergeStateStatus": "CLEAN", "reviewDecision": None,
        "author": {"login": "someone"},
        "baseRefName": "main", "headRefName": "f", "headRefOid": head,
        "isCrossRepository": False,
        "reviews": {"nodes": reviews},
        "reviewRequests": {"nodes": []},
        "reviewThreads": {"nodes": []},
        "commits": {"nodes": [{"commit": {"oid": head, "statusCheckRollup": {
            "state": "SUCCESS", "contexts": {"nodes": checks}}}}]},
        "allCommits": {"nodes": [{"commit": {"oid": head,
                                             "signature": {"isValid": True}}}]},
    }}}}, open(out, "w"))
PY
}

watch() { PATH="$STUB_DIR:$PATH" bash "$SCRIPT" -R o/r 1 --json --watch "$@"; }

echo "case: quota-dead request-review, checks settled, no ignore (baseline)"
make_stub
rc=0; out=$(watch) || rc=$?
check         "exits 0"                 "0" "$rc"
check_contains "returns on the action"  "ACTIONABLE: request-review (UNSATISFIABLE" "$out"

echo "case: same state, --ignore-action request-review -> SETTLED, not ACTIONABLE"
make_stub
rc=0; out=$(watch --ignore-action request-review) || rc=$?
check         "exits 0"                 "0" "$rc"
check_contains "reports SETTLED"        "SETTLED: NEXT is still the ignored action -> request-review" "$out"
check_absent  "no ACTIONABLE return"    "ACTIONABLE" "$out"

echo "case: quota-dead request-review, checks PENDING, ignored -> holds until timeout"
PENDING_CHECK=1 make_stub
rc=0; out=$(watch --ignore-action request-review --interval 1 --max-wait 2) || rc=$?
check         "exits 1 (timeout, not first poll)" "1" "$rc"
check_contains "reports TIMEOUT"        "TIMEOUT" "$out"
check_absent  "no ACTIONABLE return"    "ACTIONABLE" "$out"
check_absent  "no premature SETTLED"    "SETTLED" "$out"

echo "case: ignored request-review still returns on a new check failure"
FAIL_CHECK=1 make_stub
rc=0; out=$(watch --ignore-action request-review) || rc=$?
check         "exits 0"                 "0" "$rc"
check_contains "returns on the failure" "ACTIONABLE: check failed -> " "$out"
check_absent  "no SETTLED"              "SETTLED" "$out"

echo "case: ignored CI action swallows its own failing checks -> SETTLED"
FAIL_CHECK=1 make_stub
rc=0; out=$(watch --ignore-action triage-ci) || rc=$?
check         "exits 0"                 "0" "$rc"
check_contains "reports SETTLED"        "SETTLED: NEXT is still the ignored action -> triage-ci" "$out"
check_absent  "no ACTIONABLE return"    "ACTIONABLE" "$out"

echo "case: ignored NON-CI action must not eat a check failure (conflict + red check)"
FAIL_CHECK=1 MERGEABLE=CONFLICTING make_stub
rc=0; out=$(watch --ignore-action resolve-conflicts) || rc=$?
check         "exits 0"                 "0" "$rc"
check_contains "returns on the failure" "ACTIONABLE: check failed -> " "$out"
check_absent  "no SETTLED"              "SETTLED" "$out"

echo "case: --ignore-action validates its value"
rc=0; out=$(watch --ignore-action definitely-not-an-action 2>&1) || rc=$?
check         "exits 2"                 "2" "$rc"
check_contains "names the bad value"    "unknown action 'definitely-not-an-action'" "$out"

echo "case: --ignore-action takes one action per flag"
rc=0; out=$(watch --ignore-action "fix-ci triage-ci" 2>&1) || rc=$?
check         "exits 2"                 "2" "$rc"
check_contains "rejects the pair"       "one action per flag" "$out"

echo "case: --ignore-action without --watch is refused"
rc=0; out=$(PATH="$STUB_DIR:$PATH" bash "$SCRIPT" -R o/r 1 --ignore-action merge 2>&1) || rc=$?
check         "exits 2"                 "2" "$rc"
check_contains "says it needs --watch"  "only meaningful with --watch" "$out"

exit "$fail"
