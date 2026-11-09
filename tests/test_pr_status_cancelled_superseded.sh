#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: Netresearch DTT GmbH
# Regression test (#439): a cancelled check-run row whose workflow has a NEWER,
# unfinished run on the same head must not be answered with "re-run".
#
# Why this is a test: on netresearch/t3x-nr-textdb#228 the workflow "Checks"
# ran twice on one head; the older run's jobs were cancelled and the newer run
# sat waiting on its concurrency group, with no jobs and so no rows in the
# check rollup. pr-status.sh printed "cancelled : … — re-run, do not debug"
# and answered fix-ci for the cancelled required row; re-running the older run
# then cancelled the newer one (Canceling since a higher priority waiting
# request for Checks-refs/pull/228/merge exists). The newer run is visible only
# in the REST runs listing, so the stub answers that endpoint.
#
# Runs pr-status.sh against a stubbed `gh`, so it needs no network and no repo.

set -euo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/skills/git-workflow/scripts/pr-status.sh"
STUB_DIR="$(mktemp -d)"
trap 'rm -rf "$STUB_DIR"' EXIT
export XDG_CACHE_HOME="$STUB_DIR/cache"

fail=0
check() { # check <name> <expected> <actual>
    if [ "$2" = "$3" ]; then echo "  ok   $1"; else
        echo "  FAIL $1: expected '$2', got '$3'"; fail=1; fi
}
contains() { # contains <name> <needle> <haystack>
    case "$3" in
        *"$2"*) echo "  ok   $1" ;;
        *) echo "  FAIL $1: '$2' not found in output"; fail=1 ;;
    esac
}
lacks() { # lacks <name> <needle> <haystack>
    case "$3" in
        *"$2"*) echo "  FAIL $1: '$2' should not appear"; fail=1 ;;
        *) echo "  ok   $1" ;;
    esac
}

HEAD="7a1c0ffee0000000000000000000000000000228"

# RUNS_MODE: ok (serve runs.json) | fail (the runs listing errors)
# Every call to the runs endpoint is logged, so a case can assert it was not
# made at all.
cat > "$STUB_DIR/gh" <<STUB
#!/usr/bin/env bash
for a in "\$@"; do
  case "\$a" in
    repos/*/rules/branches/*)        cat "$STUB_DIR/rules.json"; exit 0 ;;
    repos/*/branches/*/protection)   echo "gh: Branch not protected (HTTP 404)" >&2; exit 1 ;;
    repos/*/actions/runs*)
      echo "\$a" >> "$STUB_DIR/runs-calls.log"
      if [ "\${RUNS_MODE:-ok}" = "fail" ]; then echo "gh: HTTP 502" >&2; exit 1; fi
      cat "$STUB_DIR/runs.json"; exit 0 ;;
  esac
done
cat "$STUB_DIR/graphql.json"
STUB
chmod +x "$STUB_DIR/gh"

# Knobs, from the environment:
#   CONCLUSION     conclusion of the "Checks / test" row in run 100 (default CANCELLED)
#   NEWER_STATUS   REST status of run 101 (default pending; "none" leaves it out)
#   NEWER_WF       workflow id of run 101 (default 7, the same workflow)
build() {
    : > "$STUB_DIR/runs-calls.log"
    python3 - "$STUB_DIR" "$HEAD" <<'PY'
import sys, json, os
d, head = sys.argv[1:3]
env = os.environ
rules = [{"type": "required_status_checks", "ruleset_id": 1, "parameters": {
    "strict_required_status_checks_policy": False,
    "required_status_checks": [{"context": "Checks / test"}]}}]
json.dump(rules, open(os.path.join(d, "rules.json"), "w"))

runs = [{"id": 100, "workflow_id": 7, "run_number": 10, "status": "completed",
         "conclusion": "cancelled", "name": "Checks"}]
newer = env.get("NEWER_STATUS", "pending")
if newer != "none":
    runs.append({"id": 101, "workflow_id": int(env.get("NEWER_WF", "7")), "run_number": 11,
                 "status": newer, "conclusion": "success" if newer == "completed" else None,
                 "name": "Checks"})
json.dump({"total_count": len(runs), "workflow_runs": runs}, open(os.path.join(d, "runs.json"), "w"))

wr = {"databaseId": 100, "runNumber": 10, "event": "pull_request",
      "createdAt": "2026-11-06T11:20:00Z", "url": "https://github.com/o/r/actions/runs/100",
      "workflow": {"databaseId": 7, "name": "Checks"}}
other = {"databaseId": 200, "runNumber": 5, "event": "pull_request",
         "createdAt": "2026-11-06T11:20:00Z", "url": "https://github.com/o/r/actions/runs/200",
         "workflow": {"databaseId": 8, "name": "Lint"}}
def row(name, conclusion, run):
    return {"__typename": "CheckRun", "name": name, "conclusion": conclusion,
            "status": "COMPLETED", "detailsUrl": "u", "startedAt": "2026-11-06T11:21:00Z",
            "checkSuite": {"status": "COMPLETED", "workflowRun": run}}
rollup = [row("Checks / test", env.get("CONCLUSION", "CANCELLED"), wr),
          row("Lint / lint", "SUCCESS", other)]
json.dump({"data": {"viewer": {"login": "someone"}, "repository": {
    "nameWithOwner": "o/r",
    "mergeCommitAllowed": True, "rebaseMergeAllowed": False, "squashMergeAllowed": False,
    "autoMergeAllowed": True,
    "pullRequest": {
        "number": 228, "title": "t", "state": "OPEN", "isDraft": False,
        "mergeable": "MERGEABLE", "mergeStateStatus": "BLOCKED",
        "reviewDecision": "APPROVED", "mergeQueueEntry": None,
        "author": {"login": "someone", "__typename": "User"},
        "baseRefName": "main", "headRefName": "f", "headRefOid": head,
        "isCrossRepository": False,
        "comments": {"nodes": []},
        "reviews": {"nodes": [{"author": {"login": "rev"}, "state": "APPROVED",
                               "commit": {"oid": head}, "body": ""}]},
        "reviewRequests": {"nodes": []},
        "reviewThreads": {"nodes": []},
        "allCommits": {"nodes": [{"commit": {"oid": head, "signature": {"isValid": True}}}]},
        "commits": {"nodes": [{"commit": {"oid": head, "statusCheckRollup": {
            "state": "FAILURE",
            "contexts": {"pageInfo": {"hasNextPage": False}, "nodes": rollup}}}}]},
    }}}}, open(os.path.join(d, "graphql.json"), "w"))
PY
}

run_json() { PATH="$STUB_DIR:$PATH" bash "$SCRIPT" -R o/r 228 --json 2>/dev/null; }
run_text() { PATH="$STUB_DIR:$PATH" bash "$SCRIPT" -R o/r 228 2>&1; }

echo "case 1: t3x-nr-textdb#228 — the cancelled row's workflow has a newer run still pending"
build
out="$(run_json)"
check    "NEXT waits for the newer run" "wait" "$(jq -r .next.action <<<"$out")"
check    "the row is not counted as failing" "0" "$(jq -r .checks.fail <<<"$out")"
check    "it is counted as pending" "1" "$(jq -r .checks.pending <<<"$out")"
check    "superseded names both runs" "Checks / test:100:101" \
         "$(jq -r '.checks.superseded[] | "\(.name):\(.run):\(.newer_run)"' <<<"$out")"
text="$(run_text)"
contains "text says to wait for the newer run" \
         "superseded  : Checks / test (run 100) — cancelled by a newer run 101 — wait for it, do not re-run" "$text"
lacks    "and gives no re-run advice" "re-run, do not debug" "$text"
contains "the pending count names it" "1 awaiting a newer run" "$text"

echo "case 2: the newer run has completed — the cancelled row needs a re-run again"
NEWER_STATUS=completed build
out="$(run_json)"
check    "required cancelled row is failing" "fix-ci" "$(jq -r .next.action <<<"$out")"
check    "nothing superseded" "0" "$(jq -r '.checks.superseded|length' <<<"$out")"
contains "re-run advice names the run" "cancelled   : Checks / test (run 100) — re-run, do not debug" "$(run_text)"

echo "case 3: the unfinished run belongs to another workflow"
NEWER_WF=8 build
check "a pending run of another workflow supersedes nothing" "fix-ci" "$(run_json | jq -r .next.action)"

echo "case 4: the runs listing cannot be read"
build
out="$(RUNS_MODE=fail run_json)"
check "a failed read keeps the old reading" "fix-ci" "$(jq -r .next.action <<<"$out")"
check "and claims no newer run" "0" "$(jq -r '.checks.superseded|length' <<<"$out")"

echo "case 5: no cancelled row — the runs listing is not read"
CONCLUSION=SUCCESS build
run_json >/dev/null
check "no runs call on a same-repo PR without a cancelled row" "0" "$(wc -l < "$STUB_DIR/runs-calls.log" | tr -d ' ')"

[ "$fail" = "0" ] && echo "All cases passed." || echo "FAILURES"
exit "$fail"
