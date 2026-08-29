#!/usr/bin/env bash
# Regression test for #255: the recorded Copilot quota wall must expire, and a
# delivered Copilot review must clear it.
#
# The marker was believed until the calendar month rolled over, and its wording
# asserted the quota "will not recover this month". Measured on one machine:
# recorded 2026-08-18, a normal Copilot review delivered 2026-08-29, the wall
# back ten minutes later. So one transient error could route every PR to
# self-review for weeks, with nothing re-probing.
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
MARKER="$XDG_CACHE_HOME/pr-status/copilot-quota-exhausted-$(date -u +%Y-%m)"

arm_marker() { # arm_marker [age-spec]
    mkdir -p "$(dirname "$MARKER")"
    printf 'copilot review quota exhausted; proven on o/r#1 at 2026-01-01T00:00:00Z\n' > "$MARKER"
    [ $# -gt 0 ] && touch -d "$1" "$MARKER"
    return 0
}
marker_exists() { [ -f "$MARKER" ] && echo yes || echo no; }

# Stub `gh`: repo demands a Copilot review; COPILOT_REVIEW=1 adds a delivered one.
make_stub() {
    printf '%s\n' '[{"type":"copilot_code_review","parameters":{}}]' > "$STUB_DIR/rules.json"
    cat > "$STUB_DIR/gh" <<STUB
#!/usr/bin/env bash
for a in "\$@"; do
  case "\$a" in
    repos/*/rules/branches/*) cat "$STUB_DIR/rules.json"; exit 0 ;;
    repos/*/branches/*/protection) exit 1 ;;
  esac
done
cat "$STUB_DIR/graphql.json"
STUB
    chmod +x "$STUB_DIR/gh"
    python3 - "$STUB_DIR/graphql.json" <<'PY'
import sys, json, os
out = sys.argv[1]
head = "deadbeefcafe"
# COPILOT_SEQ lists the Copilot rows on this head in chronological order, the
# order reviews(last:50) returns them in: "ok" a delivered review, "err" the
# quota error. Both can sit on one head, and which came last is what decides.
ERR = ("Copilot was unable to review this pull request because the user who "
       "requested the review has reached their quota limit.")
reviews = []
for kind in [s for s in os.environ.get("COPILOT_SEQ", "").split(",") if s]:
    reviews.append({"author": {"login": "copilot-pull-request-reviewer"},
                    "state": "COMMENTED", "commit": {"oid": head},
                    "body": ERR if kind == "err" else "looks fine"})
if os.environ.get("COPILOT_REVIEW", "0") == "1":
    reviews.append({"author": {"login": "copilot-pull-request-reviewer"},
                    "state": "COMMENTED", "commit": {"oid": head}, "body": "looks fine"})
json.dump({"data": {"repository": {
    "nameWithOwner": "o/r",
    "mergeCommitAllowed": True, "rebaseMergeAllowed": False, "squashMergeAllowed": False,
    "pullRequest": {
        "number": 1, "title": "t", "state": "OPEN", "isDraft": False,
        "mergeable": "MERGEABLE", "mergeStateStatus": "CLEAN", "reviewDecision": None,
        "author": {"login": "someone"},
        "baseRefName": "main", "headRefName": "f", "headRefOid": head,
        "isCrossRepository": False,
        "reviews": {"nodes": reviews},
        "reviewRequests": {"nodes": []},
        "reviewThreads": {"nodes": []},
        "commits": {"nodes": [{"commit": {"oid": head, "statusCheckRollup": {
            "state": "SUCCESS", "contexts": {"nodes": [
                {"__typename": "CheckRun", "name": "CI", "conclusion": "SUCCESS",
                 "status": "COMPLETED", "detailsUrl": "u",
                 "startedAt": "2026-01-01T00:00:00Z"}]}}}}]},
        "allCommits": {"nodes": [{"commit": {"oid": head,
                                             "signature": {"isValid": True}}}]},
    }}}}, open(out, "w"))
PY
}

status() { PATH="$STUB_DIR:$PATH" bash "$SCRIPT" -R o/r 1; }

echo "case: fresh marker is believed"
COPILOT_REVIEW=0 make_stub; arm_marker
out=$(status)
check_contains "quota wording shown" "OUT OF REVIEW QUOTA" "$out"
check          "marker kept"          "yes" "$(marker_exists)"

echo "case: the wording no longer predicts a recovery date"
check_absent "no 'will not recover this month'" "will not recover this month" "$out"
check_absent "no 'until the monthly reset'"     "until the monthly reset"     "$out"

echo "case: an expired marker is dropped and no longer believed"
COPILOT_REVIEW=0 make_stub; arm_marker "8 hours ago"
out=$(status)
check_absent "quota wording gone" "OUT OF REVIEW QUOTA" "$out"
check        "marker removed"     "no" "$(marker_exists)"

echo "case: a delivered Copilot review clears a fresh marker"
COPILOT_REVIEW=1 make_stub; arm_marker
out=$(status)
check "marker cleared by the observed review" "no" "$(marker_exists)"

echo "case: the TTL is configurable"
COPILOT_REVIEW=0 make_stub; arm_marker "2 hours ago"
out=$(PR_STATUS_QUOTA_TTL_HOURS=1 status)
check "marker removed at a 1h TTL" "no" "$(marker_exists)"

# Both rows can sit on one head. Asking only "is there a review" clears the
# marker in the second case too, where the wall is demonstrably back.
echo "case: quota error, then a delivered review -> marker cleared"
COPILOT_SEQ="err,ok" make_stub; arm_marker
out=$(status)
check "marker cleared" "no" "$(marker_exists)"

# No wording assertion here: the delivered row satisfies the review gate, so
# this snapshot goes to the merge branch, which carries no quota sentence. What
# matters is that the marker is not cleared by a review the error outlived.
echo "case: a delivered review, then the quota error -> marker stands"
COPILOT_SEQ="ok,err" make_stub; rm -f "$MARKER"
out=$(status)
check "marker re-armed" "yes" "$(marker_exists)"

exit "$fail"
