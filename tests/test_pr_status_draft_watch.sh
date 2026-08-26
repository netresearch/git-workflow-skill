#!/usr/bin/env bash
# Regression test for #228: --watch must be usable on a draft PR.
#
# Before the fix, `draft` sat near the top of the NEXT ladder and always
# answered `ready` — masking conflicts, red checks and open threads — while
# `ready` was missing from ACTIONABLE, so the watch could neither return on it
# nor hold through it via --ignore-action: it heartbeated "waiting: draft"
# into the timeout. Now draft ranks below the real-work branches, reports
# `wait` while checks run, and a settled draft returns `ready` (ignorable).
#
# The last section pins the action vocabulary: every action literal the script
# can emit must be in ACTIONABLE (watch returns on it, --ignore-action takes
# it) or in the waiting set (heartbeats). A new action landing in neither is
# how #228 happened.
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

# Stub `gh`: a draft PR, green unless told otherwise.
#   PENDING_CHECK=1 make_stub  — adds an IN_PROGRESS check (checks_settled false)
#   FAIL_CHECK=1 make_stub     — adds a COMPLETED/FAILURE check
#   OPEN_THREAD=1 make_stub    — adds one unresolved review thread
#   NO_CHECKS=1 make_stub      — zero registered check contexts
#   GHOST_REQUIRED=1 make_stub — a required context no check run ever reports
make_stub() {
    if [ "${GHOST_REQUIRED:-0}" = "1" ]; then
        printf '%s\n' '[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"ghost"}]}}]' > "$STUB_DIR/rules.json"
    else
        printf '%s\n' '[]' > "$STUB_DIR/rules.json"
    fi
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
checks = [{"__typename": "CheckRun", "name": "CI", "conclusion": "SUCCESS",
           "status": "COMPLETED", "detailsUrl": "u",
           "startedAt": "2026-01-01T00:00:00Z"}]
if os.environ.get("NO_CHECKS", "0") == "1":
    checks = []
if os.environ.get("PENDING_CHECK", "0") == "1":
    checks.append({"__typename": "CheckRun", "name": "slow", "conclusion": None,
                   "status": "IN_PROGRESS", "detailsUrl": "u",
                   "startedAt": "2026-01-01T00:00:00Z"})
if os.environ.get("FAIL_CHECK", "0") == "1":
    checks.append({"__typename": "CheckRun", "name": "broken", "conclusion": "FAILURE",
                   "status": "COMPLETED", "detailsUrl": "u",
                   "startedAt": "2026-01-01T00:00:00Z"})
threads = []
if os.environ.get("OPEN_THREAD", "0") == "1":
    threads.append({"id": "T1", "isResolved": False,
                    "comments": {"nodes": [{"databaseId": 1, "path": "f",
                                            "author": {"login": "rev"},
                                            "body": "please fix"}]}})
reviews = [{"author": {"login": "rev"}, "state": "APPROVED",
            "commit": {"oid": head}, "body": ""}]
json.dump({"data": {"repository": {
    "nameWithOwner": "o/r",
    "mergeCommitAllowed": True, "rebaseMergeAllowed": False, "squashMergeAllowed": False,
    "pullRequest": {
        "number": 1, "title": "t", "state": "OPEN", "isDraft": True,
        "mergeable": "MERGEABLE", "mergeStateStatus": "BLOCKED", "reviewDecision": None,
        "author": {"login": "someone"},
        "baseRefName": "main", "headRefName": "f", "headRefOid": head,
        "isCrossRepository": False,
        "reviews": {"nodes": reviews},
        "reviewRequests": {"nodes": []},
        "reviewThreads": {"nodes": threads},
        "commits": {"nodes": [{"commit": {"oid": head, "statusCheckRollup": {
            "state": "SUCCESS", "contexts": {"nodes": checks}}}}]},
        "allCommits": {"nodes": [{"commit": {"oid": head,
                                             "signature": {"isValid": True}}}]},
    }}}}, open(out, "w"))
PY
}

watch() { PATH="$STUB_DIR:$PATH" bash "$SCRIPT" -R o/r 1 --json --watch "$@"; }
status() { PATH="$STUB_DIR:$PATH" bash "$SCRIPT" -R o/r 1 --json; }

echo "case: draft with running checks -> wait, watch holds"
PENDING_CHECK=1 make_stub
rc=0; out=$(watch --interval 1 --max-wait 2) || rc=$?
check          "exits 1 (timeout, still waiting)" "1" "$rc"
check_contains "why names the draft and the run"  "draft — 1 check(s) still running" "$out"
check_absent   "no ACTIONABLE return"             "ACTIONABLE" "$out"

echo "case: draft with an unresolved thread -> the thread outranks the draft"
OPEN_THREAD=1 make_stub
rc=0; out=$(watch --interval 1 --max-wait 4) || rc=$?
check          "exits 0"                   "0" "$rc"
check_contains "returns on the thread"     "ACTIONABLE: resolve-threads" "$out"

echo "case: draft with a red check -> returns, draft does not mask it"
FAIL_CHECK=1 make_stub
rc=0; out=$(watch --interval 1 --max-wait 4) || rc=$?
check          "exits 0"                   "0" "$rc"
check_contains "returns on the failure"    "ACTIONABLE" "$out"
# The watch would return here even pre-fix (the check-failure early-exit is
# ladder-independent); the reorder shows in plain status, where draft used to
# mask the red check behind NEXT: ready.
rc=0; out=$(status) || rc=$?
check          "plain status names the red check" "triage-ci" "$(jq -r '.next.action' <<<"$out")"

echo "case: draft with no registered checks -> ready, not an endless wait"
NO_CHECKS=1 make_stub
rc=0; out=$(watch --interval 1 --max-wait 4) || rc=$?
check          "exits 0"                   "0" "$rc"
check_contains "returns ready"             "ACTIONABLE: ready" "$out"

echo "case: draft whose required context never dispatched -> ready, names it"
GHOST_REQUIRED=1 make_stub
rc=0; out=$(watch --interval 1 --max-wait 4) || rc=$?
check          "exits 0"                   "0" "$rc"
check_contains "returns ready"             "ACTIONABLE: ready" "$out"
check_contains "why names the missing context" "required context(s) not reported" "$out"

echo "case: settled green draft -> ready is the actionable event"
make_stub
rc=0; out=$(watch --interval 1 --max-wait 4) || rc=$?
check          "exits 0"                   "0" "$rc"
check_contains "returns ready"             "ACTIONABLE: ready" "$out"
check_contains "hands over the command"    "gh pr ready" "$out"

echo "case: settled green draft, --ignore-action ready -> SETTLED, not ACTIONABLE"
make_stub
rc=0; out=$(watch --ignore-action ready --interval 1 --max-wait 4) || rc=$?
check          "exits 0"                   "0" "$rc"
check_contains "reports SETTLED"           "SETTLED: NEXT is still the ignored action -> ready" "$out"
check_absent   "no ACTIONABLE return"      "ACTIONABLE" "$out"

echo "case: plain status on a settled draft still says ready"
make_stub
rc=0; out=$(status) || rc=$?
check          "exits 0"                   "0" "$rc"
check          "NEXT is ready" "ready" "$(jq -r '.next.action' <<<"$out")"

echo "vocabulary: every emitted action is either actionable or waiting"
# The waiting set heartbeats instead of returning; everything else must be in
# ACTIONABLE so the watch can return on it and --ignore-action can name it.
WAITING="wait await-checks await-review await-capacity rules-unavailable"
actionable=$(sed -n 's/^ACTIONABLE="\(.*\)"$/\1/p' "$SCRIPT")
check "ACTIONABLE was found in the script" "yes" "$([ -n "$actionable" ] && echo yes || echo no)"
emitted=$(grep -oE 'action:"[a-z-]+"' "$SCRIPT" | sed 's/action:"//; s/"$//' | sort -u)
for a in $emitted; do
    case " $actionable $WAITING " in
        *" $a "*) echo "  ok   emitted action '$a' is classified" ;;
        *) echo "  FAIL emitted action '$a' is neither ACTIONABLE nor waiting"; fail=1 ;;
    esac
done
emitted_padded=" ${emitted//$'\n'/ } "
for a in $actionable; do
    case "$emitted_padded" in
        *" $a "*) echo "  ok   actionable '$a' is actually emitted" ;;
        *) echo "  FAIL actionable '$a' is never emitted — dead vocabulary"; fail=1 ;;
    esac
done

exit "$fail"
