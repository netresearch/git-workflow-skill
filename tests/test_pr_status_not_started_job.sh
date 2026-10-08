#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: Netresearch DTT GmbH
# Regression test: a job that never got a runner is named apart from a failure.
#
# A queued job whose runner GitHub could not acquire is concluded FAILURE with
# zero steps and annotated "The job was not started because it repeatedly
# failed to be acquired (5 attempts)." pr-status.sh counted those rows as
# ordinary failures, so a pull request whose code was fine read as 13 red
# checks and answered fix-ci (netresearch/t3x-nr-textdb#169, 2026-10-07: the
# jobs concluded between 15:08 and 15:16 UTC, inside a GitHub Actions incident;
# a re-run turned all of them green). Such a row still shuts the gate, but it is
# listed under "not started", and when it is the only kind of failure NEXT is
# rerun-ci with the run ids, or wait while a job of that run is still going.
# Only that annotation qualifies: other zero-step failures carry a different
# message and stay ordinary failures.
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

# Stub `gh`.
#   ROW=starved|real|thirdparty|startup|otherzero — the red row.
#   REQUIRED=1 makes the red row a required check (default: nothing required).
#   EXTRA=green|pending|real — the second row, in the same run unless real.
#   THREAD=1 adds one unresolved review thread.
#   REQPEND=1 adds a required check "ci / Req", still running, in run 9.
#   MS=<state> overrides the mergeStateStatus.
make_stub() {
    python3 - "$STUB_DIR/rules.json" <<'PY2'
import json, os, sys
ctx = []
if os.environ.get("REQUIRED") == "1":
    ctx.append({"context": "ci / PHPStan (8.2, ^14.3)"})
if os.environ.get("REQPEND") == "1":
    ctx.append({"context": "ci / Req"})
rules = [{"type": "required_status_checks", "parameters": {"required_status_checks": ctx}}] if ctx else []
json.dump(rules, open(sys.argv[1], "w"))
PY2
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
extra = os.environ.get("EXTRA", "green")
def suite(run):
    return {"status": "COMPLETED", "workflowRun": {
        "databaseId": run, "runNumber": 1, "event": "pull_request",
        "createdAt": "2026-10-07T14:24:40Z", "url": f"run/{run}",
        "workflow": {"databaseId": 70, "name": "CI"}}}
red = {"__typename": "CheckRun", "name": "ci / PHPStan (8.2, ^14.3)",
       "conclusion": "FAILURE", "status": "COMPLETED", "detailsUrl": "job/1",
       "startedAt": "2026-10-07T14:24:45Z", "steps": {"totalCount": 0},
       "annotations": {"nodes": [
           {"message": "The ubuntu-latest label will migrate to Ubuntu 26"},
           {"message": "The job was not started because it repeatedly failed to be acquired (5 attempts)."}]},
       "checkSuite": suite(7)}
if row == "real":
    red["steps"] = {"totalCount": 6}
elif row == "thirdparty":
    red["name"] = "SonarCloud Code Analysis"
    red["checkSuite"] = {"status": "COMPLETED", "workflowRun": None}
elif row == "startup":
    red["conclusion"] = "STARTUP_FAILURE"
elif row == "otherzero":
    red["annotations"] = {"nodes": [{"message":
        "The job was not started because recent account payments have failed."}]}
second = {"__typename": "CheckRun", "name": "ci / Unit Tests",
          "conclusion": "SUCCESS", "status": "COMPLETED", "detailsUrl": "job/2",
          "startedAt": "2026-10-07T14:24:45Z", "steps": {"totalCount": 9},
          "checkSuite": suite(7)}
if extra == "pending":
    second.update({"conclusion": None, "status": "IN_PROGRESS", "steps": {"totalCount": 3}})
elif extra == "real":
    second.update({"name": "lint / Lint", "conclusion": "FAILURE",
                   "steps": {"totalCount": 5}, "checkSuite": suite(8)})
checks = [red, second]
if os.environ.get("REQPEND") == "1":
    checks.append({"__typename": "CheckRun", "name": "ci / Req", "conclusion": None,
                   "status": "IN_PROGRESS", "detailsUrl": "job/3", "startedAt": "2026-10-07T14:30:00Z",
                   "steps": {"totalCount": 2}, "checkSuite": suite(9)})
json.dump({"data": {"repository": {
    "nameWithOwner": "o/r",
    "mergeCommitAllowed": True, "rebaseMergeAllowed": False, "squashMergeAllowed": False,
    "pullRequest": {
        "number": 1, "title": "t", "state": "OPEN", "isDraft": False,
        "mergeable": "MERGEABLE",
        "mergeStateStatus": os.environ.get("MS") or ("BLOCKED" if os.environ.get("REQUIRED") == "1" else "UNSTABLE"),
        "reviewDecision": "APPROVED",
        "author": {"login": "someone"},
        "baseRefName": "main", "headRefName": "f", "headRefOid": head,
        "isCrossRepository": False,
        "reviews": {"nodes": [{"author": {"login": "rev"}, "state": "APPROVED",
                               "commit": {"oid": head}, "body": ""}]},
        "reviewRequests": {"nodes": []},
        "reviewThreads": {"nodes": [{"id": "T1", "isResolved": False, "isOutdated": False,
            "comments": {"nodes": [{"databaseId": 1, "path": "f", "author": {"login": "rev"},
                                    "body": "please fix"}]}}] if os.environ.get("THREAD") == "1" else []},
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

echo "case: the only failure never started, its run has concluded -> rerun-ci with the run id"
ROW=starved make_stub
out=$(status_json)
check "listed as not started" '.checks.not_started == ["ci / PHPStan (8.2, ^14.3)"]' "$out"
check "names its run"         '.checks.not_started_runs == [7]' "$out"
check "still counted failing" '.checks.fail == 1' "$out"
check "NEXT is rerun-ci"      '.next.action == "rerun-ci"' "$out"
check "cmd re-runs that run"  '.next.cmd == "gh run rerun 7 --repo o/r --failed"' "$out"
txt=$(status_text)
case "$txt" in
    *"not started : ci / PHPStan (8.2, ^14.3) — no runner acquired"*"(run 7)"*) echo "  ok   text names it and its run" ;;
    *) echo "  FAIL text names it and its run"; fail=1 ;;
esac

wout=$(PATH="$STUB_DIR:$PATH" timeout 60 bash "$SCRIPT" -R o/r 1 --watch 2>&1 || true)
case "$wout" in
    *"ACTIONABLE: rerun-ci"*) echo "  ok   --watch returns on rerun-ci" ;;
    *) echo "  FAIL --watch returns on rerun-ci: $(printf '%s' "$wout" | head -1)"; fail=1 ;;
esac
case "$wout" in
    *"ACTIONABLE: check failed"*) echo "  FAIL --watch reported a check failure for a not-started row"; fail=1 ;;
    *) echo "  ok   --watch does not report it as a check failure" ;;
esac

echo "case: the same as a required check -> rerun-ci, not fix-ci"
ROW=starved REQUIRED=1 make_stub
out=$(status_json)
check "NEXT is rerun-ci" '.next.action == "rerun-ci"' "$out"

echo "case: a job of the same run still running -> wait, not rerun-ci"
ROW=starved EXTRA=pending make_stub
out=$(status_json)
check "NEXT is wait"            '.next.action == "wait"' "$out"
check "names the busy run"      '.checks.not_started_busy_runs == [7]' "$out"
check "wait names the rows"     '.next.why | startswith("not started: ci / PHPStan (8.2, ^14.3)")' "$out"
check "no false nothing-failed" '.next.why | contains("nothing has failed") | not' "$out"

echo "case: an open thread while the run is busy -> resolve-threads, not a silent wait"
ROW=starved EXTRA=pending THREAD=1 make_stub
out=$(status_json)
check "NEXT is resolve-threads" '.next.action == "resolve-threads"' "$out"

echo "case: required not-started row plus a real non-required failure -> triage-ci names the real one"
ROW=starved REQUIRED=1 EXTRA=real make_stub
out=$(status_json)
check "NEXT is triage-ci"        '.next.action == "triage-ci"' "$out"
check "names the real failure"   '.next.why | startswith("non-required check(s) failing: lint / Lint — ")' "$out"
check "says the required row holds the gate" '.next.why | contains("the gate is BLOCKED on required not-started row(s): ci / PHPStan")' "$out"
check "no false UNSTABLE claim"  '.next.why | contains("UNSTABLE") | not' "$out"

echo "case: concluded not-started run, a real failure and a pending required check -> wait names the re-runnable run"
ROW=starved EXTRA=real REQPEND=1 make_stub
out=$(status_json)
check "NEXT is wait"             '.next.action == "wait"' "$out"
check "no empty run list"        '.next.why | contains("run(s)  have") | not' "$out"
check "gives the re-run command" '.next.why | contains("run(s) 7 can be re-run now: gh run rerun 7 --repo o/r --failed")' "$out"

echo "case: busy not-started run while mergeState reads CLEAN -> wait, never merge"
ROW=starved EXTRA=pending MS=CLEAN make_stub
out=$(status_json)
check "NEXT is wait"             '.next.action == "wait"' "$out"

echo "case: a real failure besides the not-started one -> triage-ci names both"
ROW=starved EXTRA=real make_stub
out=$(status_json)
check "NEXT is triage-ci"       '.next.action == "triage-ci"' "$out"
check "other failure listed"    '.checks.failing_other == ["lint / Lint"]' "$out"

echo "case: failed Actions job that ran steps -> an ordinary failure"
ROW=real make_stub
out=$(status_json)
check "not listed as not started" '.checks.not_started == []' "$out"
check "counted failing"           '.checks.fail == 1' "$out"
check "NEXT is triage-ci"         '.next.action == "triage-ci"' "$out"

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

echo "case: zero steps with a different annotation -> an ordinary failure"
ROW=otherzero make_stub
out=$(status_json)
check "not listed as not started" '.checks.not_started == []' "$out"
check "counted failing"           '.checks.fail == 1' "$out"

exit "$fail"
