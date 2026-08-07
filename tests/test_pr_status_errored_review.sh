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
    # Unquoted delimiter so $STUB_DIR expands now; \$@ stays literal for the
    # stub. Avoids `sed -i`, whose no-suffix form is GNU-only and fails the
    # suite on BSD/macOS with an error pointing at sed, not at the test.
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
    python3 - "$STUB_DIR/graphql.json" "$@" <<'PY'
import sys, json
out, bodies = sys.argv[1], sys.argv[2:]
head = "deadbeefcafe"
reviews = [{"author": {"login": "copilot-pull-request-reviewer"},
            "state": "COMMENTED", "commit": {"oid": head}, "body": b}
           for b in bodies]
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

# Same stub, but each arg is "author|state|body" so a case can mix a Copilot
# error row with a human review on the same head.
make_stub_reviews() {
    local rules
    if [ -n "${RULES_JSON:-}" ]; then
        rules="$RULES_JSON"
    else
        rules='[{"type":"copilot_code_review","parameters":{}}]'
    fi
    printf '%s\n' "$rules" > "$STUB_DIR/rules.json"
    # Unquoted delimiter so $STUB_DIR expands now; \$@ stays literal for the
    # stub. Avoids `sed -i`, whose no-suffix form is GNU-only and fails the
    # suite on BSD/macOS with an error pointing at sed, not at the test.
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
    python3 - "$STUB_DIR/graphql.json" "$@" <<'PY'
import sys, json
out, specs = sys.argv[1], sys.argv[2:]
head = "deadbeefcafe"
reviews = []
approved = False
for s in specs:
    who, state, body = s.split("|", 2)
    reviews.append({"author": {"login": who}, "state": state,
                    "commit": {"oid": head}, "body": body})
    approved = approved or state == "APPROVED"
json.dump({"data": {"repository": {
    "nameWithOwner": "o/r",
    "mergeCommitAllowed": True, "rebaseMergeAllowed": False, "squashMergeAllowed": False,
    "pullRequest": {
        "number": 1, "title": "t", "state": "OPEN", "isDraft": False,
        "mergeable": "MERGEABLE", "mergeStateStatus": "CLEAN",
        "reviewDecision": ("APPROVED" if approved else None),
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

# Repeated failures change the advice, not the action: the retry command is
# dropped so an agent following NEXT stops re-requesting a bot that is out of
# quota. The action stays request-review because the ruleset genuinely still has
# no bot review — anything else would claim a state the tool cannot observe.
echo "case 7: two errors — same action, no retry command, different advice"
make_stub "$ERR_GENERIC" "$ERR_QUOTA"
check "copilot_error_count" "2"              "$(run_flag copilot_error_count)"
check "next.action"         "request-review" "$(run_next)"
check "next.cmd absent"     "null"           "$(run_flag 'next.cmd')"
if status | jq -e '.next.why | test("Review the diff yourself")' >/dev/null; then
    echo "  ok   why carries the self-review instruction"
else
    echo "  FAIL why does not carry the self-review instruction"
    fail=1
fi

# One retry IS offered on the first failure — an outage may simply have cleared.
echo "case 7b: one error — retry command still offered"
make_stub "$ERR_GENERIC"
check "copilot_error_count" "1" "$(run_flag copilot_error_count)"
case "$(run_flag 'next.cmd')" in
    *"repos/o/r/pulls/1/requested_reviewers"*)
        echo "  ok   retry command offered on the first failure, with the real repo" ;;
    *)  echo "  FAIL first failure should offer a re-request cmd naming the repo"
        fail=1 ;;
esac

# Regression for a dead end that shipped once: an earlier version escalated to a
# distinct "review-yourself" action guarded on has_review_on_head. A review by
# the PR author is excluded from that gate by design, and the operator driving
# this script IS usually the author — so carrying out the instruction produced a
# row that was discarded and the action re-fired forever, with pr-merge.sh
# refusing anything but "merge". Every emitted action must be one --watch and
# pr-merge.sh recognise.
echo "case 8: author self-reviews after two errors — action stays a known one"
make_stub_reviews \
  "copilot-pull-request-reviewer|COMMENTED|$ERR_GENERIC" \
  "copilot-pull-request-reviewer|COMMENTED|$ERR_QUOTA" \
  "someone|COMMENTED|Reviewed this myself, the bot was unavailable."
check "has_review_on_head" "false"          "$(run_flag has_review_on_head)"
check "next.action"        "request-review" "$(run_next)"

# The action alone cannot detect this regression — it is request-review either
# way. What distinguishes "stop retrying" from "retry forever" is the cmd, so
# assert on that. An earlier revision moved the two-strikes suppression inside
# the $needs_copilot guard, which handed the retry command back to every repo
# without the ruleset; this case passed regardless until the cmd was checked.
echo "case 9: NO ruleset + two errors — retry command dropped here too"
RULES_JSON='[]' make_stub "$ERR_GENERIC" "$ERR_QUOTA"
check "next.action"     "request-review" "$(run_next)"
check "next.cmd absent" "null"           "$(run_flag 'next.cmd')"
if status | jq -e '.next.why | test("Review the diff yourself")' >/dev/null; then
    echo "  ok   why carries the self-review instruction without the ruleset"
else
    echo "  FAIL why lacks the self-review instruction when no ruleset is set"
    fail=1
fi

# Keeps the recovery path covered: a real APPROVED review by someone other than
# the author opens the gate even though the error rows are still on the head.
# Also the only case that exercises the reviewDecision == APPROVED branch.
echo "case 10: NO ruleset + two errors + human APPROVED — gate opens"
RULES_JSON='[]' make_stub_reviews \
  "copilot-pull-request-reviewer|COMMENTED|$ERR_GENERIC" \
  "copilot-pull-request-reviewer|COMMENTED|$ERR_QUOTA" \
  "a-human|APPROVED|LGTM"
check "has_review_on_head" "true"  "$(run_flag has_review_on_head)"
check "next.action"        "merge" "$(run_next)"

# Finding from review: the comment on case 10 claimed it covered the
# reviewDecision == APPROVED branch. It does not — case 10 lands on merge, while
# that string lives only on the generic "no review on head" branch. Reaching it
# needs APPROVED with an EMPTY $head_reviews, i.e. the approval sitting on an
# older commit. That gap is why the stale-approval warning could go missing from
# the exhausted variant unnoticed.
echo "case 11: stale APPROVED on an older commit + two errors — warning survives"
RULES_JSON='[]' make_stub_reviews \
  "copilot-pull-request-reviewer|COMMENTED|$ERR_GENERIC" \
  "copilot-pull-request-reviewer|COMMENTED|$ERR_QUOTA" \
  "someone|APPROVED|approved on an older commit"
check "has_review_on_head" "false"          "$(run_flag has_review_on_head)"
check "next.action"        "request-review" "$(run_next)"
check "next.cmd absent"    "null"           "$(run_flag 'next.cmd')"
for phrase in "do not merge unreviewed" "sits on an older commit"; do
    if status | jq -e --arg p "$phrase" '.next.why | test($p)' >/dev/null; then
        echo "  ok   why keeps: $phrase"
    else
        echo "  FAIL why lost: $phrase"
        fail=1
    fi
done

if [ "$fail" -eq 0 ]; then
    echo "all pass"
else
    echo "FAILURES"
    exit 1
fi
