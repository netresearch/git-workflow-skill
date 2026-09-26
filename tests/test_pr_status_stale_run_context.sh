#!/usr/bin/env bash
# Regression test: a required context reported only by a SUPERSEDED run of its
# workflow is named as the cause, instead of ending the ladder at investigate.
#
# Why this is a test: on netresearch/t3x-nr-image-optimize#207 (head 1d23d093)
# the workflow "Checks" ran twice on one head, both with event pull_request:
# run #212 carried `security / Composer Audit` (SUCCESS), and run #213 (the
# ready_for_review action) skipped the calling job `security` as a whole, so
# the context never appeared in it. GitHub showed the context as "Expected —
# Waiting for status to be reported" and kept the PR BLOCKED; pr-status.sh
# counted #212's row as reported and answered `investigate`. Case 1 is that
# state, with the rollup rows as read from GraphQL on 2026-09-27.
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
check_contains() { # check_contains <name> <needle> <haystack>
    case "$3" in
        *"$2"*) echo "  ok   $1" ;;
        *) echo "  FAIL $1: no '$2' in output"; fail=1 ;;
    esac
}

HEAD="1d23d09301167969b1cc481c358b57baf5484f95"

# The investigate path makes REST reads of its own; answer them as an
# unprotected branch with no extra check-runs or suites, so they add nothing.
cat > "$STUB_DIR/gh" <<STUB
#!/usr/bin/env bash
for a in "\$@"; do
  case "\$a" in
    repos/*/rules/branches/*)        cat "$STUB_DIR/rules.json"; exit 0 ;;
    repos/*/branches/*/protection)   echo "gh: Branch not protected (HTTP 404)" >&2; exit 1 ;;
    repos/*/commits/*/check-runs*)   echo '{"total_count":0,"check_runs":[]}'; exit 0 ;;
    repos/*/commits/*/check-suites*) echo '{"total_count":0,"check_suites":[]}'; exit 0 ;;
  esac
done
cat "$STUB_DIR/graphql.json"
STUB
chmod +x "$STUB_DIR/gh"

# Knobs, from the environment:
#   NEWEST_HAS     yes: run #213 carries `security / Composer Audit` too
#   NEWEST_STATUS  check-suite status of run #213 (default COMPLETED)
#   NEWEST_EVENT   event of run #213 (default pull_request)
#   TRUNCATED      yes: the rollup reports hasNextPage
build() {
    python3 - "$STUB_DIR" "$HEAD" <<'PY'
import sys, json, os
d, head = sys.argv[1:3]
env = os.environ
GHA = 15368
rules = [{"type": "required_status_checks", "ruleset_id": 14253254, "parameters": {
    "strict_required_status_checks_policy": False,
    "required_status_checks": [{"context": c, "integration_id": GHA}
                               for c in ["ci / Code Style", "security / Composer Audit"]]}}]
json.dump(rules, open(os.path.join(d, "rules.json"), "w"))

def run(number, rid, event, created, wf_id=296890775, wf_name="Checks"):
    return {"databaseId": rid, "runNumber": number, "event": event, "createdAt": created,
            "url": "https://github.com/o/r/actions/runs/%d" % rid,
            "workflow": {"databaseId": wf_id, "name": wf_name}}

r212 = run(212, 36269874998, "pull_request", "2026-09-26T20:32:25Z")
r213 = run(213, 36271092593, env.get("NEWEST_EVENT", "pull_request"), "2026-09-26T20:53:58Z")
r854 = run(854, 36269875001, "pull_request", "2026-09-26T20:32:25Z", 188649181, "CI")
s213 = env.get("NEWEST_STATUS", "COMPLETED")

def row(name, conclusion, wr, suite_status="COMPLETED", started="2026-09-26T20:40:00Z"):
    return {"__typename": "CheckRun", "name": name, "conclusion": conclusion,
            "status": "COMPLETED", "detailsUrl": "u", "startedAt": started,
            "checkSuite": {"status": suite_status, "workflowRun": wr}}

rollup = [
    row("security", "SKIPPED", r213, s213, "2026-09-26T20:54:00Z"),
    row("security / Composer Audit", "SUCCESS", r212),
    row("All security checks", "SUCCESS", r212),
    row("All security checks", "SUCCESS", r213, s213, "2026-09-26T20:55:00Z"),
    row("ci / Code Style", "SUCCESS", r854),
]
if env.get("NEWEST_HAS", "no") == "yes":
    rollup.append(row("security / Composer Audit", "SUCCESS", r213, s213, "2026-09-26T20:56:00Z"))

json.dump({"data": {"viewer": {"login": "someone"}, "repository": {
    "nameWithOwner": "o/r",
    "mergeCommitAllowed": True, "rebaseMergeAllowed": False, "squashMergeAllowed": False,
    "autoMergeAllowed": True,
    "pullRequest": {
        "number": 207, "title": "t", "state": "OPEN", "isDraft": False,
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
            "state": "SUCCESS",
            "contexts": {"pageInfo": {"hasNextPage": env.get("TRUNCATED", "no") == "yes"},
                         "nodes": rollup}}}}]},
    }}}}, open(os.path.join(d, "graphql.json"), "w"))
PY
}

run_json() { PATH="$STUB_DIR:$PATH" bash "$SCRIPT" -R o/r 207 --json; }
run_text() { PATH="$STUB_DIR:$PATH" bash "$SCRIPT" -R o/r 207; }

echo "case 1: t3x-nr-image-optimize#207 — the required context exists only in the superseded run"
build
out="$(run_json)"
check "next.action" "fix-required-context" "$(jq -r .next.action <<<"$out")"
check "one stale context, named" "security / Composer Audit" \
      "$(jq -r '[.next.stale_contexts[].context] | join(",")' <<<"$out")"
check "stale run and newest run, with events" "Checks:212:pull_request:213:pull_request" \
      "$(jq -r '.next.stale_contexts[0] | "\(.workflow):\(.reported_in.run_number):\(.reported_in.event):\(.newest_run.run_number):\(.newest_run.event)"' <<<"$out")"
check "run ids carried" "36269874998:36271092593" \
      "$(jq -r '.next.stale_contexts[0] | "\(.reported_in.run_id):\(.newest_run.run_id)"' <<<"$out")"
check_contains "why names both runs" "only in Checks run #212 (pull_request), while the newest run #213 (pull_request)" \
      "$(jq -r .next.why <<<"$out")"
check_contains "why labels the mechanism as inferred" "inferred" "$(jq -r .next.why <<<"$out")"
check_contains "why names the durable fix" "aggregate gate job" "$(jq -r .next.why <<<"$out")"
check "cmd re-fires the events" "gh pr close 207 --repo o/r && gh pr reopen 207 --repo o/r" \
      "$(jq -r .next.cmd <<<"$out")"
check "the context still counts as reported (undispatched untouched)" "0" \
      "$(jq -r '.undispatched | length' <<<"$out")"
check "no evidence block: the cause is named" "null" "$(jq -r .next.evidence <<<"$out")"
text="$(run_text)"
check_contains "text NEXT line" "NEXT: fix-required-context — 1 required context(s) reported only by a SUPERSEDED workflow run" "$text"
check_contains "text lists the stale context" \
      "stale ctx   : security / Composer Audit — Checks run #212 https://github.com/o/r/actions/runs/36269874998 superseded by run #213" "$text"
wout="$(PATH="$STUB_DIR:$PATH" timeout 60 bash "$SCRIPT" -R o/r 207 --watch --interval 1 --max-wait 4 || true)"
check_contains "--watch returns on it" "ACTIONABLE: fix-required-context" "$wout"

echo "case 2: the newest run carries the context too -> unchanged (investigate)"
NEWEST_HAS=yes build
out="$(run_json)"
check "next.action" "investigate" "$(jq -r .next.action <<<"$out")"
check "no stale list" "null" "$(jq -r .next.stale_contexts <<<"$out")"
check_contains "why unchanged" "The cause is NOT determined" "$(jq -r .next.why <<<"$out")"

echo "case 3: the newest run is still in progress -> not flagged"
NEWEST_STATUS=IN_PROGRESS build
check "next.action" "investigate" "$(jq -r .next.action <<<"$(run_json)")"

echo "case 4: the newer run has a different event (push) -> not flagged"
NEWEST_EVENT=push build
check "next.action" "investigate" "$(jq -r .next.action <<<"$(run_json)")"

echo "case 5: the rollup is truncated -> absence unproven, not flagged"
TRUNCATED=yes build
check "next.action" "investigate" "$(jq -r .next.action <<<"$(run_json)")"

exit "$fail"
