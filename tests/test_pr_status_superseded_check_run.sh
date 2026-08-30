#!/usr/bin/env bash
# Regression test: a superseded check-run must not keep the gate shut.
#
# One head can carry several check-runs of the same name. A close/reopen, a
# workflow_dispatch or a `gh run rerun` of a superseded run starts a NEW run
# whose rows join the old ones in statusCheckRollup instead of replacing
# them. GitHub's own merge state reads only the newest row per name and
# reports CLEAN; pr-status.sh counted both, answered triage-ci for the old
# red row, and pr-merge.sh refused a merge the gate had already opened
# (t3x-nr-image-optimize#173: `fuzz / Fuzz Tests` red at 15:03 and green at
# 18:30 on one SHA).
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

# Stub `gh`: no rulesets, so every check is non-required.
#   NEWEST=SUCCESS|FAILURE|QUEUED — state of the newer row. QUEUED models a
#   re-run that has not started yet: status QUEUED, startedAt null.
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
newest = os.environ.get("NEWEST", "SUCCESS")
older = "FAILURE" if newest == "SUCCESS" else "SUCCESS"
# The old row comes FIRST in the rollup, as GitHub returns it — the fix must
# pick by startedAt, not by position.
if newest == "QUEUED":
    newer_row = {"__typename": "CheckRun", "name": "fuzz / Fuzz Tests",
                 "conclusion": None, "status": "QUEUED",
                 "detailsUrl": "run/2", "startedAt": None}
else:
    newer_row = {"__typename": "CheckRun", "name": "fuzz / Fuzz Tests",
                 "conclusion": newest, "status": "COMPLETED",
                 "detailsUrl": "run/2", "startedAt": "2026-08-30T18:30:00Z"}
checks = [
    {"__typename": "CheckRun", "name": "fuzz / Fuzz Tests",
     "conclusion": older, "status": "COMPLETED",
     "detailsUrl": "run/1", "startedAt": "2026-08-30T15:03:00Z"},
    newer_row,
    {"__typename": "CheckRun", "name": "ci / Unit Tests",
     "conclusion": "SUCCESS", "status": "COMPLETED",
     "detailsUrl": "run/2", "startedAt": "2026-08-30T18:30:00Z"},
]
json.dump({"data": {"repository": {
    "nameWithOwner": "o/r",
    "mergeCommitAllowed": True, "rebaseMergeAllowed": False, "squashMergeAllowed": False,
    "pullRequest": {
        "number": 1, "title": "t", "state": "OPEN", "isDraft": False,
        "mergeable": "MERGEABLE",
        "mergeStateStatus": "CLEAN" if newest == "SUCCESS" else "UNSTABLE",
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
            "state": {"SUCCESS": "SUCCESS", "QUEUED": "PENDING"}.get(newest, "FAILURE"),
            "contexts": {"nodes": checks}}}}]},
        "allCommits": {"nodes": [{"commit": {"oid": head,
                                             "signature": {"isValid": True}}}]},
    }}}}, open(out, "w"))
PY
}

status() { PATH="$STUB_DIR:$PATH" bash "$SCRIPT" -R o/r 1 --json; }

echo "case: old row red, newest row green -> the superseded row is dropped"
NEWEST=SUCCESS make_stub
out=$(status)
check_absent   "no triage-ci"                 '"action": "triage-ci"' "$out"
check_absent   "old run not listed"           'run/1' "$out"
check_contains "counts one row for the name"  '"total": 2' "$out"
check_contains "gate is open"                 '"action": "merge"' "$out"

echo "case: old row green, newest row red -> still red (newest wins, not greenest)"
NEWEST=FAILURE make_stub
out=$(status)
check_contains "returns triage-ci"            '"action": "triage-ci"' "$out"
check_contains "names the failing check"      'fuzz / Fuzz Tests' "$out"
check_contains "points at the newest run"     'run/2' "$out"

echo "case: old row red, re-run still QUEUED (startedAt null) -> the queued row wins, gate waits"
NEWEST=QUEUED make_stub
out=$(status)
check_absent   "no triage-ci for the old row"   '"action": "triage-ci"' "$out"
check_absent   "old run not listed"             'run/1' "$out"
check_contains "waits on the queued re-run"     '"action": "wait"' "$out"
check_contains "reports it as queued"           '"queued": 1' "$out"

exit "$fail"
