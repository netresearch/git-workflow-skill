#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: Netresearch DTT GmbH
# Regression test: a job that never got a runner is named apart from a failure.
#
# When the runner pool is exhausted, GitHub gives up acquiring a runner for a
# queued job after about 45 to 50 minutes and concludes it FAILURE with zero
# steps, annotated "The job was not started because it repeatedly failed to be
# acquired (5 attempts)." pr-status.sh counted those rows as ordinary failures,
# so a pull request whose code was fine read as 13 red checks and answered
# fix-ci (netresearch/t3x-nr-textdb#169, 2026-10-07: six PHPStan / unit /
# functional jobs, runner_name empty, steps 0; a re-run turned all of them
# green). The row still shuts the gate, but it is listed under "not started".
#
# Runs pr-status.sh against a stubbed `gh`, so it needs no network and no repo.

set -euo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/skills/git-workflow/scripts/pr-status.sh"
STUB_DIR="$(mktemp -d)"
trap 'rm -rf "$STUB_DIR"' EXIT

fail=0
check() { # check <name> <jq filter yielding true> <json>
    if jq -e "$2" >/dev/null <<<"$3"; then
        echo "  ok   $1"
    else
        echo "  FAIL $1: $2"; fail=1
    fi
}

export XDG_CACHE_HOME="$STUB_DIR/cache"

# Stub `gh`: no rulesets, so every check is non-required.
#   ROW=starved|real|thirdparty|startup — the one red row besides a green one.
make_stub() {
    printf '%s\n' '[]' > "$STUB_DIR/rules.json"
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
row = os.environ["ROW"]
suite = {"status": "COMPLETED", "workflowRun": {
    "databaseId": 7, "runNumber": 1, "event": "pull_request",
    "createdAt": "2026-10-07T14:24:40Z", "url": "run/7",
    "workflow": {"databaseId": 70, "name": "CI"}}}
red = {"__typename": "CheckRun", "name": "ci / PHPStan (8.2, ^14.3)",
       "conclusion": "FAILURE", "status": "COMPLETED", "detailsUrl": "job/1",
       "startedAt": "2026-10-07T14:24:45Z", "steps": {"totalCount": 0},
       "checkSuite": suite}
if row == "real":
    red["steps"] = {"totalCount": 6}
elif row == "thirdparty":
    red["name"] = "SonarCloud Code Analysis"
    red["checkSuite"] = {"status": "COMPLETED", "workflowRun": None}
elif row == "startup":
    red["conclusion"] = "STARTUP_FAILURE"
checks = [
    red,
    {"__typename": "CheckRun", "name": "ci / Unit Tests",
     "conclusion": "SUCCESS", "status": "COMPLETED", "detailsUrl": "job/2",
     "startedAt": "2026-10-07T14:24:45Z", "steps": {"totalCount": 9},
     "checkSuite": suite},
]
json.dump({"data": {"repository": {
    "nameWithOwner": "o/r",
    "mergeCommitAllowed": True, "rebaseMergeAllowed": False, "squashMergeAllowed": False,
    "pullRequest": {
        "number": 1, "title": "t", "state": "OPEN", "isDraft": False,
        "mergeable": "MERGEABLE", "mergeStateStatus": "UNSTABLE",
        "reviewDecision": "APPROVED",
        "author": {"login": "someone"},
        "baseRefName": "main", "headRefName": "f", "headRefOid": head,
        "isCrossRepository": False,
        "reviews": {"nodes": [{"author": {"login": "rev"}, "state": "APPROVED",
                               "commit": {"oid": head}, "body": ""}]},
        "reviewRequests": {"nodes": []},
        "reviewThreads": {"nodes": []},
        "comments": {"nodes": []},
        "commits": {"nodes": [{"commit": {"oid": head, "statusCheckRollup": {
            "state": "FAILURE", "contexts": {"nodes": checks}}}}]},
        "allCommits": {"nodes": [{"commit": {"oid": head,
                                             "signature": {"isValid": True}}}]},
    }}}}, open(out, "w"))
PY
}

status_json() { PATH="$STUB_DIR:$PATH" bash "$SCRIPT" -R o/r 1 --json; }
status_text() { PATH="$STUB_DIR:$PATH" bash "$SCRIPT" -R o/r 1; }

echo "case: failed Actions job with zero steps -> not started, gate still shut"
ROW=starved make_stub
out=$(status_json)
check "listed as not started" '.checks.not_started == ["ci / PHPStan (8.2, ^14.3)"]' "$out"
check "still counted failing" '.checks.fail == 1' "$out"
check "gate stays shut"       '.next.action != "merge"' "$out"
txt=$(status_text)
case "$txt" in
    *"not started : ci / PHPStan (8.2, ^14.3) — no runner acquired"*) echo "  ok   text names it" ;;
    *) echo "  FAIL text names it"; fail=1 ;;
esac

echo "case: failed Actions job that ran steps -> an ordinary failure"
ROW=real make_stub
out=$(status_json)
check "not listed as not started" '.checks.not_started == []' "$out"
check "counted failing"           '.checks.fail == 1' "$out"

echo "case: third-party check run without steps -> an ordinary failure"
ROW=thirdparty make_stub
out=$(status_json)
check "not listed as not started" '.checks.not_started == []' "$out"
check "counted failing"           '.checks.fail == 1' "$out"

echo "case: STARTUP_FAILURE with zero steps -> an ordinary failure (a broken workflow file)"
ROW=startup make_stub
out=$(status_json)
check "not listed as not started" '.checks.not_started == []' "$out"
check "counted failing"           '.checks.fail == 1' "$out"

exit "$fail"
