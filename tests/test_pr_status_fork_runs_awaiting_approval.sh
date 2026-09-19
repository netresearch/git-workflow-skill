#!/usr/bin/env bash
# Regression test: workflow runs on a fork head that await maintainer approval
# are reported, and they outrank the review rung.
#
# GitHub requires that approval after EVERY new SHA on a fork pull request, and
# an unapproved run is not a check run: it contributes nothing to the rollup.
# pr-status.sh therefore reported `0 pending` and NEXT: request-review while
# eight required contexts had not started and never would have — a NEXT line
# naming an action that cannot unblock the pull request, which is the failure
# mode the tool exists to prevent (#310, netresearch/simple-ldap-go#227).
#
# Runs pr-status.sh against a stubbed `gh`, so it needs no network and no repo.

set -euo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/skills/git-workflow/scripts/pr-status.sh"
STUB_DIR="$(mktemp -d)"
trap 'rm -rf "$STUB_DIR"' EXIT

export XDG_CACHE_HOME="$STUB_DIR/cache"

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

# CROSS selects same-repo vs fork; RUNS_JSON is what the Actions endpoint
# answers. The GraphQL payload is constant: everything that DID report is
# green, nothing is pending, no review on the head — the exact state in which
# the ladder used to say request-review.
make_stub() {
    printf '%s\n' "${RUNS_JSON}" > "$STUB_DIR/runs.json"
    cat > "$STUB_DIR/gh" <<STUB
#!/usr/bin/env bash
for a in "\$@"; do
  case "\$a" in
    repos/*/rules/branches/*)      echo '[]'; exit 0 ;;
    repos/*/branches/*/protection) exit 1 ;;
    repos/*/actions/runs*)         cat "$STUB_DIR/runs.json"; exit 0 ;;
  esac
done
cat "$STUB_DIR/graphql.json"
STUB
    chmod +x "$STUB_DIR/gh"
    CROSS="${CROSS:-true}" python3 - "$STUB_DIR/graphql.json" <<'PY'
import sys, json, os
out = sys.argv[1]
head = "11717139aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
cross = os.environ.get("CROSS", "true") == "true"
json.dump({"data": {
    "viewer": {"login": "cybot"},
    "repository": {
        "nameWithOwner": "o/r",
        "mergeCommitAllowed": True, "rebaseMergeAllowed": False, "squashMergeAllowed": False,
        "pullRequest": {
            "number": 227, "title": "t", "state": "OPEN", "isDraft": False,
            "mergeable": "MERGEABLE", "mergeStateStatus": "BLOCKED", "reviewDecision": None,
            "author": {"login": "contributor", "__typename": "User"},
            "baseRefName": "main", "headRefName": "f", "headRefOid": head,
            "isCrossRepository": cross,
            "comments": {"nodes": []},
            "reviews": {"nodes": []},
            "latestReviews": {"nodes": []},
            "reviewRequests": {"nodes": []},
            "reviewThreads": {"nodes": []},
            "commits": {"nodes": [{"commit": {"oid": head, "statusCheckRollup": {
                "state": "SUCCESS", "contexts": {"nodes": [
                    {"__typename": "StatusContext", "context": "DCO", "state": "SUCCESS",
                     "targetUrl": "u"}]}}}}]},
            "allCommits": {"nodes": [{"commit": {"oid": head,
                                                 "signature": {"isValid": True}}}]},
        }}}}, open(out, "w"))
PY
}

json() { PATH="$STUB_DIR:$PATH" bash "$SCRIPT" -R o/r 227 --json; }
human() { PATH="$STUB_DIR:$PATH" bash "$SCRIPT" -R o/r 227; }

WAITING='{"workflow_runs":[
  {"id":111,"name":"Tests","status":"completed","conclusion":"action_required"},
  {"id":222,"name":"Lint","status":"completed","conclusion":"action_required"},
  {"id":333,"name":"Tests","status":"completed","conclusion":"success"}
]}'

echo "case: fork PR with two runs awaiting approval"
CROSS=true RUNS_JSON="$WAITING" make_stub
out=$(json)
check "two runs reported"        "2"   "$(jq -r '.awaiting_approval | length' <<<"$out")"
check "the approved one is out"  "false" "$(jq -r '[.awaiting_approval[].id] | index(333) != null' <<<"$out")"
check "next names the approval"  "approve-workflow-runs" "$(jq -r '.next.action' <<<"$out")"
check_contains "cmd approves both" "actions/runs/111/approve" "$(jq -r '.next.cmd' <<<"$out")"
check_contains "and the second"    "actions/runs/222/approve" "$(jq -r '.next.cmd' <<<"$out")"

echo "case: it outranks the review rung, which cannot unblock this PR"
hout=$(human || true)
check_absent "does not say request-review" "NEXT: request-review" "$hout"

echo "case: same-repository PR — endpoint not consulted, behaviour unchanged"
# The stub would happily answer for a same-repo PR too, so a non-empty list
# here would mean the cross-repository guard is not doing its job.
CROSS=false RUNS_JSON="$WAITING" make_stub
out=$(json)
check "no runs collected"        "0" "$(jq -r '.awaiting_approval | length' <<<"$out")"
check "ladder falls through"     "false" "$([ "$(jq -r '.next.action' <<<"$out")" = "approve-workflow-runs" ] && echo true || echo false)"

echo "case: fork PR with nothing awaiting approval — no new rung"
CROSS=true RUNS_JSON='{"workflow_runs":[{"id":333,"name":"Tests","status":"completed","conclusion":"success"}]}' make_stub
out=$(json)
check "empty list"               "0" "$(jq -r '.awaiting_approval | length' <<<"$out")"
check "ladder falls through"     "false" "$([ "$(jq -r '.next.action' <<<"$out")" = "approve-workflow-runs" ] && echo true || echo false)"

echo "case: the Actions endpoint fails — understate, never invent"
CROSS=true RUNS_JSON="$WAITING" make_stub
cat > "$STUB_DIR/gh" <<STUB
#!/usr/bin/env bash
for a in "\$@"; do
  case "\$a" in
    repos/*/rules/branches/*)      echo '[]'; exit 0 ;;
    repos/*/branches/*/protection) exit 1 ;;
    repos/*/actions/runs*)         echo 'gh: 403' >&2; exit 1 ;;
  esac
done
cat "$STUB_DIR/graphql.json"
STUB
chmod +x "$STUB_DIR/gh"
rc=0; out=$(json) || rc=$?
check "still exits 0"            "0" "$rc"
check "empty list"               "0" "$(jq -r '.awaiting_approval | length' <<<"$out")"

exit "$fail"
