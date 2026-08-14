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

# Same stub, but each arg is "author|state|body" — optionally with a fourth
# field "older" to place that review on a PREVIOUS commit rather than the head.
# Needed to model a stale approval honestly: GitHub does not let an author
# approve their own PR, so "APPROVED by the author on the head" is a state that
# cannot occur in production and would test the author filter instead of the
# commit-staleness filter the warning is actually about.
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
    # Split the optional trailing flag off the RIGHT, so a body containing a
    # pipe stays intact instead of being silently truncated into the flag slot.
    if s.endswith("|older"):
        s, oid = s[: -len("|older")], "0ldc0mm1t"
    else:
        oid = head
    who, state, body = s.split("|", 2)
    reviews.append({"author": {"login": who}, "state": state,
                    "commit": {"oid": oid}, "body": body})
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

# Quota is not an outage: the error body names the quota limit, the quota is
# monthly, and no re-request on any PR will succeed until the reset. The retry
# command must be withheld even on the FIRST failure, and the advice must say
# the state will not change this month — this is the message an operator sees
# exactly once instead of rediscovering the wall per PR.
echo "case 7c: quota error — no retry cmd even on the FIRST failure, monthly advice"
make_stub "$ERR_QUOTA"
check "copilot_quota_hit"   "true"           "$(run_flag copilot_quota_hit)"
check "copilot_error_count" "1"              "$(run_flag copilot_error_count)"
check "next.action"         "request-review" "$(run_next)"
check "next.cmd absent"     "null"           "$(run_flag 'next.cmd')"
if status | jq -e '.next.why | test("MONTHLY")' >/dev/null; then
    echo "  ok   why states the quota is monthly and will not recover"
else
    echo "  FAIL why lacks the monthly-quota advice"
    fail=1
fi

# The quota detector must be able to stay quiet: a generic outage row must not
# trip it, or every outage would be misreported as a month-long dead end.
echo "case 7d: generic outage only — quota flag stays false"
make_stub "$ERR_GENERIC"
check "copilot_quota_hit" "false" "$(run_flag copilot_quota_hit)"

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

# The approval is by ANOTHER user and sits on an OLDER commit — the state the
# warning is written for, and the only way to reach the reviewDecision ==
# APPROVED branch through the commit filter rather than the author filter.
# Run for both repo populations: the ruleset branch and the generic branch serve
# disjoint sets (with the ruleset active the generic one is unreachable), which
# is how a fix landed on one of them and left the other unwarned.
echo "case 11: stale APPROVED on an older commit + two errors — NO ruleset"
RULES_JSON='[]' make_stub_reviews \
  "copilot-pull-request-reviewer|COMMENTED|$ERR_GENERIC" \
  "copilot-pull-request-reviewer|COMMENTED|$ERR_QUOTA" \
  "a-human|APPROVED|approved before the last push|older"
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

echo "case 12: same, WITH the copilot ruleset — the other branch must warn too"
make_stub_reviews \
  "copilot-pull-request-reviewer|COMMENTED|$ERR_GENERIC" \
  "copilot-pull-request-reviewer|COMMENTED|$ERR_QUOTA" \
  "a-human|APPROVED|approved before the last push|older"
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

# The copilot branch is NOT gated on has_review_on_head, so wording written for
# "nothing reviewed this head" must not be asserted there unconditionally: with a
# valid approval ON the head, claiming otherwise tells the operator to disregard
# a current review.
echo "case 13: two errors + valid APPROVED ON the head — no false claims"
make_stub_reviews \
  "copilot-pull-request-reviewer|COMMENTED|$ERR_GENERIC" \
  "copilot-pull-request-reviewer|COMMENTED|$ERR_QUOTA" \
  "a-human|APPROVED|LGTM on the current head"
check "has_review_on_head" "true"           "$(run_flag has_review_on_head)"
# Pin the branch too: asserting only absences passes vacuously if this stops
# being the branch that answers.
check "next.action"        "request-review" "$(run_next)"
for phrase in "no review on the current head" "sits on an older commit"; do
    if status | jq -e --arg p "$phrase" '.next.why | test($p)' >/dev/null; then
        echo "  FAIL why falsely claims: $phrase"
        fail=1
    else
        echo "  ok   why does not claim: $phrase"
    fi
done

# The single-error branch had neither warning while the generic one did.
echo "case 14: ONE error + stale APPROVED — warnings on the first strike too"
make_stub_reviews \
  "copilot-pull-request-reviewer|COMMENTED|$ERR_GENERIC" \
  "a-human|APPROVED|approved before the last push|older"
check "copilot_error_count" "1" "$(run_flag copilot_error_count)"
for phrase in "do not merge unreviewed" "sits on an older commit"; do
    if status | jq -e --arg p "$phrase" '.next.why | test($p)' >/dev/null; then
        echo "  ok   why keeps: $phrase"
    else
        echo "  FAIL why lost: $phrase"
        fail=1
    fi
done

# has_review_on_head is true for ANY non-author review, including a COMMENTED
# one — and a reply to a review thread registers as exactly that. Using it as
# the staleness test drops the warning after a single reply, while the approval
# is still sitting on the pre-push commit.
echo "case 15: stale APPROVED + a COMMENTED reply on the head — warning survives"
make_stub_reviews \
  "copilot-pull-request-reviewer|COMMENTED|$ERR_GENERIC" \
  "a-human|APPROVED|approved before the last push|older" \
  "other-human|COMMENTED|replying to a thread"
check "has_review_on_head" "true"           "$(run_flag has_review_on_head)"
check "next.action"        "request-review" "$(run_next)"
if status | jq -e '.next.why | test("sits on an older commit")' >/dev/null; then
    echo "  ok   staleness warning survives a COMMENTED reply"
else
    echo "  FAIL staleness warning dropped by a COMMENTED reply"
    fail=1
fi

# Case 15 uses two distinct logins, so no key collides and it cannot catch a
# lossy per-author projection. The SAME reviewer approving the head and then
# commenting on it is what collapses the state.
echo "case 16: same reviewer approves the head then comments — no false staleness"
make_stub_reviews \
  "copilot-pull-request-reviewer|COMMENTED|$ERR_GENERIC" \
  "a-human|APPROVED|LGTM on the current head" \
  "a-human|COMMENTED|one more thought on the same head"
check "next.action" "request-review" "$(run_next)"
if status | jq -e '.next.why | test("sits on an older commit")' >/dev/null; then
    echo "  FAIL claims staleness for an approval that is on the head"
    fail=1
else
    echo "  ok   no false staleness after the approver comments"
fi

# render/--json must not hide the approval either: it is the only surface that
# shows per-reviewer state, and it sits directly above the corrected why.
echo "case 17: approve-then-comment stays visible in reviews_on_head"
make_stub_reviews \
  "copilot-pull-request-reviewer|COMMENTED|$ERR_GENERIC" \
  "a-human|APPROVED|LGTM on the current head" \
  "a-human|COMMENTED|one more thought on the same head"
check "reviews_on_head[a-human]" "APPROVED+COMMENTED" "$(run_flag '"reviews_on_head"."a-human"')"

# Chronology matters, and the fixture has to make alphabetical order DISAGREE
# with it — otherwise `unique` produces the same string and the case proves
# nothing. CHANGES_REQUESTED then APPROVED: sorted gives APPROVED first (the
# superseded state leading), chronological keeps the current one last.
echo "case 18: CHANGES_REQUESTED then APPROVED — chronology, not alphabet"
make_stub_reviews \
  "copilot-pull-request-reviewer|COMMENTED|$ERR_GENERIC" \
  "a-human|CHANGES_REQUESTED|not yet" \
  "a-human|APPROVED|fixed, good now"
check "reviews_on_head[a-human]" "CHANGES_REQUESTED+APPROVED" "$(run_flag '"reviews_on_head"."a-human"')"

# No other fixture repeats a state, so the dedupe branch of the reduce is never
# reached by the suite. Recurrence is what separates keep-first from keep-last.
echo "case 19: state recurs — the trailing entry must be the current one"
make_stub_reviews \
  "copilot-pull-request-reviewer|COMMENTED|$ERR_GENERIC" \
  "a-human|CHANGES_REQUESTED|not yet" \
  "a-human|APPROVED|fixed" \
  "a-human|CHANGES_REQUESTED|found something else"
check "reviews_on_head[a-human]" "APPROVED+CHANGES_REQUESTED" "$(run_flag '"reviews_on_head"."a-human"')"

if [ "$fail" -eq 0 ]; then
    echo "all pass"
else
    echo "FAILURES"
    exit 1
fi
