#!/usr/bin/env bash
# Regression test: a FAILED Copilot review must not count as a review.
#
# Copilot answers a failed review as an ordinary COMMENTED row ("Copilot
# encountered an error and was unable to review…", "…reached their quota
# limit"). Before the fix, pr-status.sh counted any Copilot review row on the
# head as a review and reported NEXT=merge for a PR nothing had read.
#
# Runs pr-status.sh against a stubbed `gh`, so it needs no network and no repo.

set -euo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/skills/git-workflow/scripts/pr-status.sh"
STUB_DIR="$(mktemp -d)"
trap 'rm -rf "$STUB_DIR"' EXIT

ERR_GENERIC="Copilot encountered an error and was unable to review this pull request. You can try again by re-requesting a review."
ERR_QUOTA="Copilot was unable to review this pull request because the user who requested the review has reached their quota limit."
REAL_REVIEW="Pull request review complete. Two suggestions below, neither blocking."

fail=0
check() { # check <name> <expected> <actual>
    if [ "$2" = "$3" ]; then
        echo "  ok   $1"
    else
        echo "  FAIL $1: expected '$2', got '$3'"
        fail=1
    fi
}

# Stub `gh`: rules endpoint answers $RULES_JSON, graphql answers a payload built
# from the review bodies passed in. Bodies never pass through shell quoting.
#   make_stub <body>...                 — repo HAS the copilot_code_review ruleset
#   RULES_JSON='[]' make_stub <body>... — repo has NO ruleset
make_stub() {
    # Assigned in a branch, not via ${VAR:-default}: a literal } inside the
    # default value closes the parameter expansion early and mangles the JSON.
    local rules
    if [ -n "${RULES_JSON:-}" ]; then
        rules="$RULES_JSON"
    else
        rules='[{"type":"copilot_code_review","parameters":{}}]'
    fi
    printf '%s\n' "$rules" > "$STUB_DIR/rules.json"
    cat > "$STUB_DIR/gh" <<'STUB'
#!/usr/bin/env bash
for a in "$@"; do
  case "$a" in
    repos/*/rules/branches/*) cat "$STUB_DIR/rules.json"; exit 0 ;;
  esac
done
cat "$STUB_DIR/graphql.json"
STUB
    sed -i "s|\$STUB_DIR|$STUB_DIR|g" "$STUB_DIR/gh"
    chmod +x "$STUB_DIR/gh"
    python3 - "$STUB_DIR/graphql.json" "$@" <<'PY'
import sys, json
out, bodies = sys.argv[1], sys.argv[2:]
head = "deadbeefcafe"
reviews = [{"author": {"login": "copilot-pull-request-reviewer"},
            "state": "COMMENTED", "commit": {"oid": head}, "body": b}
           for b in bodies]
json.dump({"data": {"repository": {
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

status() { PATH="$STUB_DIR:$PATH" bash "$SCRIPT" -R o/r 1 --json; }
run_next() { status | jq -r '.next.action'; }
run_flag() { status | jq -r ".$1"; }

echo "case 1: Copilot errored (generic failure) — must NOT count as a review"
make_stub "$ERR_GENERIC"
check "copilot_review_errored"     "true"           "$(run_flag copilot_review_errored)"
check "has_copilot_review_on_head" "false"          "$(run_flag has_copilot_review_on_head)"
check "next.action"                "request-review" "$(run_next)"

echo "case 2: Copilot errored (quota exhausted) — same"
make_stub "$ERR_QUOTA"
check "copilot_review_errored"     "true"           "$(run_flag copilot_review_errored)"
check "next.action"                "request-review" "$(run_next)"

echo "case 3: a real Copilot review — still counts, gate opens"
make_stub "$REAL_REVIEW"
check "copilot_review_errored"     "false"          "$(run_flag copilot_review_errored)"
check "has_copilot_review_on_head" "true"           "$(run_flag has_copilot_review_on_head)"
check "next.action"                "merge"          "$(run_next)"

echo "case 4: a real review merely containing the phrase mid-sentence — counts"
make_stub "I was unable to review the generated fixtures, but the rest looks fine."
check "copilot_review_errored"     "false"          "$(run_flag copilot_review_errored)"
check "next.action"                "merge"          "$(run_next)"

# The filter must apply to has_review_on_head, not only to the Copilot view.
# Otherwise a repo without the ruleset never reaches the Copilot branches and
# falls through to "merge — clean" on an error row.
echo "case 5: NO copilot ruleset + error row — generic review gate must still hold"
RULES_JSON='[]' make_stub "$ERR_GENERIC"
check "has_review_on_head" "false"          "$(run_flag has_review_on_head)"
check "next.action"        "request-review" "$(run_next)"

# The error row stays on the head forever. Without checking that no valid review
# landed, the recovery path (error -> re-request -> success) loops on
# request-review.
echo "case 6: error row + later successful review on same head — gate opens"
make_stub "$ERR_GENERIC" "$REAL_REVIEW"
check "copilot_review_errored"     "true"  "$(run_flag copilot_review_errored)"
check "has_copilot_review_on_head" "true"  "$(run_flag has_copilot_review_on_head)"
check "next.action"                "merge" "$(run_next)"

echo "case 7: two errors — stop retrying, say review it yourself"
make_stub "$ERR_GENERIC" "$ERR_QUOTA"
check "copilot_error_count" "2"               "$(run_flag copilot_error_count)"
check "next.action"         "review-yourself" "$(run_next)"

if [ "$fail" -eq 0 ]; then
    echo "all pass"
else
    echo "FAILURES"
    exit 1
fi
