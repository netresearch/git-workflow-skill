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
#   KEEP_MARKER=1 make_stub …           — keep the quota marker a previous case
#                                         (or a previous run in the same case)
#                                         left behind
# Setting up a scenario clears the quota marker by default. It is the one piece
# of state that survives an invocation, so without this the first case feeding a
# quota body would silently change the verdict of every case after it.
make_stub() {
    [ "${KEEP_MARKER:-0}" = "1" ] || clear_marker
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
import sys, json, os
out, bodies = sys.argv[1], sys.argv[2:]
head = "deadbeefcafe"
# COMMENTS_JSON: issue comments on the PR, as [{"author": ..., "body": ...}] —
# the surface the Self-review attestation (#203) is read from.
comments = [{"author": {"login": c["author"]}, "body": c["body"],
             "url": "https://example.test/c"}
            for c in json.loads(os.environ.get("COMMENTS_JSON", "[]"))]
# Env overrides so the signature/settled ladder branches are testable:
#   MERGE_STATE (default CLEAN), SIGNED (default 1),
#   PENDING_CHECK=1 adds an IN_PROGRESS check run (checks_settled -> false).
merge_state = os.environ.get("MERGE_STATE", "CLEAN")
signed = os.environ.get("SIGNED", "1") == "1"
review_decision = os.environ.get("REVIEW_DECISION") or None
checks = [{"__typename": "CheckRun", "name": "CI", "conclusion": "SUCCESS",
           "status": "COMPLETED", "detailsUrl": "u",
           "startedAt": "2026-01-01T00:00:00Z"}]
if os.environ.get("PENDING_CHECK", "0") == "1":
    checks.append({"__typename": "CheckRun", "name": "slow", "conclusion": None,
                   "status": "IN_PROGRESS", "detailsUrl": "u",
                   "startedAt": "2026-01-01T00:00:00Z"})
reviews = [{"author": {"login": "copilot-pull-request-reviewer"},
            "state": "COMMENTED", "commit": {"oid": head}, "body": b}
           for b in bodies]
requests = [{"requestedReviewer": {"login": r}}
            for r in json.loads(os.environ.get("REVIEW_REQUESTS_JSON", "[]"))]
json.dump({"data": {"repository": {
    "nameWithOwner": "o/r",
    "mergeCommitAllowed": True, "rebaseMergeAllowed": False, "squashMergeAllowed": False,
    "pullRequest": {
        "number": 1, "title": "t", "state": "OPEN", "isDraft": False,
        "mergeable": "MERGEABLE", "mergeStateStatus": merge_state, "reviewDecision": review_decision,
        "author": {"login": "someone"},
        "baseRefName": "main", "headRefName": "f", "headRefOid": head,
        "isCrossRepository": False,
        "comments": {"nodes": comments},
        "reviews": {"nodes": reviews},
        "reviewRequests": {"nodes": requests},
        "reviewThreads": {"nodes": []},
        "commits": {"nodes": [{"commit": {"oid": head, "statusCheckRollup": {
            "state": "SUCCESS", "contexts": {"nodes": checks}}}}]},
        "allCommits": {"nodes": [{"commit": {"oid": head,
                                             "signature": {"isValid": signed}}}]},
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
    [ "${KEEP_MARKER:-0}" = "1" ] || clear_marker
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

# pr-status.sh remembers a proven quota wall under $XDG_CACHE_HOME/pr-status and
# reads it back on every later run, so the cache has to live in the throwaway
# stub dir: otherwise the suite answers differently on a machine whose operator
# hit the wall this month, and writes into their real cache while doing it.
export XDG_CACHE_HOME="$STUB_DIR/cache"
marker_path() {
    printf '%s/pr-status/copilot-quota-exhausted-%s\n' "$XDG_CACHE_HOME" "$(date -u +%Y-%m)"
}
clear_marker() { rm -rf "$XDG_CACHE_HOME/pr-status"; }
plant_marker() {
    mkdir -p "$XDG_CACHE_HOME/pr-status"
    printf 'planted by the test suite\n' > "$(marker_path)"
}
# Derived from the script's own month (UTC), not from the local date: on the
# first of a month the two can name different months for a few hours, and the
# case would then plant a marker for the CURRENT month and assert it is ignored.
prev_month() {
    python3 -c "
import datetime
cur = datetime.datetime.strptime('$(date -u +%Y-%m)', '%Y-%m').date()
print((cur - datetime.timedelta(days=1)).strftime('%Y-%m'))
"
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
check "next.reason"         "bot-review-unsatisfiable" "$(run_flag 'next.reason')"
# Was test("MONTHLY"), pinning the claim that the quota "will not recover this
# month" — withdrawn in #255, where a wall recorded on the 18th was followed by
# a delivered review on the 29th. What still has to be said is that the wall is
# account-wide, so another PR is no way around it; when it lifts is now stated
# as unknown, and the marker expires instead of being believed to the reset.
if status | jq -e '.next.why | test("account-wide")' >/dev/null; then
    echo "  ok   why states the quota is account-wide"
else
    echo "  FAIL why lacks the account-wide advice"
    fail=1
fi
if status | jq -e '.next.why | test("will not recover this month")' >/dev/null; then
    echo "  FAIL why still predicts a recovery date"
    fail=1
else
    echo "  ok   why no longer predicts when the quota returns"
fi

# The quota detector must be able to stay quiet: a generic outage row must not
# trip it, or every outage would be misreported as a month-long dead end.
echo "case 7d: generic outage only — quota flag stays false"
make_stub "$ERR_GENERIC"
check "copilot_quota_hit" "false" "$(run_flag copilot_quota_hit)"

# --- Quota marker: the wall is account-wide, the evidence is per PR ---------
# A PR nobody ever requested a Copilot review on carries no error row at all, so
# every case above is blind to a quota that is already exhausted — and the
# ladder handed those PRs a re-request command GitHub rejects (netresearch/maint
# #52 and #53). The marker is what carries the fact from the PR that proved it.
echo "case Q1: a quota error is written to the month-keyed marker"
make_stub "$ERR_QUOTA"
status >/dev/null
if [ -f "$(marker_path)" ]; then
    echo "  ok   marker written for the current month"
else
    echo "  FAIL no marker at $(marker_path)"
    fail=1
fi

# The marker must be as quiet as the flag: an outage is not a month-long wall,
# and a marker written for one would suppress every re-request until the reset.
echo "case Q2: a generic outage writes no marker"
make_stub "$ERR_GENERIC"
status >/dev/null
if [ -f "$(marker_path)" ]; then
    echo "  FAIL an outage row left a quota marker behind"
    fail=1
else
    echo "  ok   no marker for a generic outage"
fi

# The regression this change exists for: ruleset active, no Copilot row on the
# head at all, quota already proven elsewhere. Before the marker this answered
# request-review WITH the POST command.
echo "case Q3: marker + no Copilot row (ruleset) — quota advice, no retry cmd"
make_stub
plant_marker
check "copilot_quota_hit"       "false"          "$(run_flag copilot_quota_hit)"
check "copilot_quota_exhausted" "true"           "$(run_flag copilot_quota_exhausted)"
check "next.action"             "request-review" "$(run_next)"
check "next.cmd absent"         "null"           "$(run_flag 'next.cmd')"
if status | jq -e '.next.why | test("OUT OF REVIEW QUOTA")' >/dev/null; then
    echo "  ok   why carries the quota guidance"
else
    echo "  FAIL why does not name the exhausted quota"
    fail=1
fi
# Remembered is not measured: the why must say which of the two it is, and name
# the file, or the operator has no way to undo a wrongly recorded wall.
if status | jq -e --arg m "$(marker_path)" '.next.why | index($m) != null' >/dev/null; then
    echo "  ok   why names the marker file it read"
else
    echo "  FAIL why does not name the marker file"
    fail=1
fi

# The generic gate serves the repos without the ruleset and re-requests the same
# bot, so the suppression has to reach it too — the trap a previous fix fell
# into by putting the check inside the $needs_copilot guard.
echo "case Q4: marker + NO ruleset — retry command dropped here too"
RULES_JSON='[]' make_stub
plant_marker
check "next.action"     "request-review" "$(run_next)"
check "next.cmd absent" "null"           "$(run_flag 'next.cmd')"

# The quota resets monthly, so a marker must expire with its month — and by its
# NAME, since any write refreshes an mtime.
echo "case Q5: a marker from the previous month is ignored"
make_stub
mkdir -p "$XDG_CACHE_HOME/pr-status"
printf 'stale\n' > "$XDG_CACHE_HOME/pr-status/copilot-quota-exhausted-$(prev_month)"
check "copilot_quota_exhausted" "false" "$(run_flag copilot_quota_exhausted)"
case "$(run_flag 'next.cmd')" in
    *"repos/o/r/pulls/1/requested_reviewers"*)
        echo "  ok   last month's marker does not suppress the re-request" ;;
    *)  echo "  FAIL a stale marker suppressed the re-request command"
        fail=1 ;;
esac

# Remembering is an optimisation; refusing to answer is not. A cache directory
# that cannot be written must cost one wasted re-request, never a status query.
# Skipped as root, where the mode bits do not bite and the case would pass
# without ever exercising the failure.
echo "case Q6: an unwritable cache directory does not break the run"
if [ "$(id -u)" = "0" ]; then
    echo "  skip running as root — the read-only cache dir would be writable"
else
    make_stub "$ERR_QUOTA"
    mkdir -p "$STUB_DIR/ro-cache"
    chmod 500 "$STUB_DIR/ro-cache"
    if out=$(XDG_CACHE_HOME="$STUB_DIR/ro-cache" PATH="$STUB_DIR:$PATH" \
             bash "$SCRIPT" -R o/r 1 --json) \
       && [ "$(jq -r '.next.action' <<<"$out")" = "request-review" ]; then
        echo "  ok   status still answered with an unwritable cache dir"
    else
        echo "  FAIL an unwritable cache dir broke the run"
        fail=1
    fi
    chmod 700 "$STUB_DIR/ro-cache"
fi

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
echo "case 13: two errors + valid APPROVED ON the head — the approval satisfies the policy"
make_stub_reviews \
  "copilot-pull-request-reviewer|COMMENTED|$ERR_GENERIC" \
  "copilot-pull-request-reviewer|COMMENTED|$ERR_QUOTA" \
  "a-human|APPROVED|LGTM on the current head"
check "has_review_on_head" "true"  "$(run_flag has_review_on_head)"
# This case asserted request-review until #214. Correcting the WHY was only half
# of it: the action was wrong too. The ruleset branch states its own demand as
# the never-merge-unreviewed POLICY rather than a host gate (a Copilot review
# does not count toward required approvals, and GitHub reports CLEAN here) — and
# an APPROVED review on this head satisfies that policy. While it answered
# request-review, pr-merge.sh --self-reviewed took the unsatisfiable leg and
# wrote "the review this pull request demands is unsatisfiable" into permanent
# PR history on seven PRs that were approved at the time.
check "next.action"        "merge" "$(run_next)"
# The false-attestation trigger specifically: --self-reviewed keys on this.
check "next.reason absent" "null"  "$(run_flag 'next.reason')"
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
# merge since #214, for the same reason as case 13 — the approval is on the head.
echo "case 16: same reviewer approves the head then comments — no false staleness"
make_stub_reviews \
  "copilot-pull-request-reviewer|COMMENTED|$ERR_GENERIC" \
  "a-human|APPROVED|LGTM on the current head" \
  "a-human|COMMENTED|one more thought on the same head"
check "next.action" "merge" "$(run_next)"
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

# --- #214: an approval on the head must not be reported as an unsatisfiable ---
# --- review demand. Cases 13/16 cover the errored-row leg; this is the leg  ---
# --- the reported PRs actually took.                                       ---
# netresearch/t3x-nr-llm#860 and six siblings: Copilot was never asked on the
# head at all (no error row, copilot_review_errored false), the wall was known
# only from the month marker, and github-actions had APPROVED the head minutes
# earlier. The marker leg answered request-review with
# reason=bot-review-unsatisfiable, which is the exact input pr-merge.sh
# --self-reviewed keys on to post its permanent "unsatisfiable" attestation.
echo "case 20: quota MARKER + no copilot row + APPROVED on head — no false dead end"
make_stub_reviews "a-human|APPROVED|LGTM on the current head"
plant_marker
check "copilot_quota_exhausted" "true"  "$(run_flag copilot_quota_exhausted)"
check "copilot_review_errored"  "false" "$(run_flag copilot_review_errored)"
check "has_review_on_head"      "true"  "$(run_flag has_review_on_head)"
check "next.action"             "merge" "$(run_next)"
check "next.reason absent"      "null"  "$(run_flag 'next.reason')"

# The twin that must NOT move: same marker, same missing copilot row, but the
# approval sits on an older commit. Nothing has read this head, so the dead end
# is real and the attestation path stays open. Without this, case 20 could be
# satisfied by deleting the marker leg outright.
echo "case 20b: same, but the approval is STALE — the dead end is still reported"
make_stub_reviews "a-human|APPROVED|approved before the last push|older"
plant_marker
check "has_review_on_head" "false"                     "$(run_flag has_review_on_head)"
check "next.action"        "request-review"            "$(run_next)"
check "next.reason"        "bot-review-unsatisfiable"  "$(run_flag 'next.reason')"


# --- Signature gate (#187): BLOCKED + unsigned + all green must name the ---
# --- signature, even when a quota-errored Copilot row sits on the head    ---
echo "case S1: BLOCKED + unsigned + quota error row — fix-signatures outranks request-review"
MERGE_STATE=BLOCKED SIGNED=0 make_stub "$ERR_QUOTA"
check "next.action" "fix-signatures" "$(run_next)"
if status | jq -e '.next.why | test("classic branch protection")' >/dev/null; then
    echo "  ok   why names the invisible classic protection"
else
    echo "  FAIL why does not name classic branch protection"
    fail=1
fi

echo "case S2: BLOCKED + signed — the signature gate must stay quiet"
MERGE_STATE=BLOCKED SIGNED=1 make_stub "$ERR_QUOTA"
check "next.action" "request-review" "$(run_next)"

echo "case S3: CLEAN + unsigned — no signature rule visible, merge stays open"
MERGE_STATE=CLEAN SIGNED=0 make_stub "$REAL_REVIEW"
check "next.action" "merge" "$(run_next)"

echo "case S4: BLOCKED + unsigned + REVIEW_REQUIRED — review cause outranks the signature guess"
MERGE_STATE=BLOCKED SIGNED=0 REVIEW_DECISION=REVIEW_REQUIRED make_stub "$ERR_QUOTA"
if [ "$(run_next)" = "fix-signatures" ]; then
    echo "  FAIL fired fix-signatures although a required review explains the BLOCKED"
    fail=1
else
    echo "  ok   signature branch stays quiet when reviewDecision explains BLOCKED"
fi

# --- Watch settle-gate (#186): request-review with unsettled CI must WAIT ---
watch() { PATH="$STUB_DIR:$PATH" bash "$SCRIPT" -R o/r 1 --watch --interval 1 --max-wait 2; }
echo "case W1: watch + pending check + no review — holds until timeout, no ACTIONABLE"
PENDING_CHECK=1 make_stub
out=$(watch || true)
case "$out" in
    *"ACTIONABLE: request-review"*)
        echo "  FAIL watch emitted request-review while CI was unsettled"; fail=1 ;;
    *TIMEOUT*)
        echo "  ok   watch held (timeout) instead of firing early" ;;
    *)  echo "  FAIL unexpected watch output: $(printf '%s' "$out" | head -2)"; fail=1 ;;
esac

echo "case W2: watch + settled + no review — returns immediately"
make_stub
out=$(watch || true)
case "$out" in
    *"ACTIONABLE: request-review"*) echo "  ok   immediate return on settled CI" ;;
    *) echo "  FAIL expected immediate ACTIONABLE: request-review"; fail=1 ;;
esac

echo "case W3: watch + pending check + QUOTA error — holds for CI, no premature return"
PENDING_CHECK=1 make_stub "$ERR_QUOTA"
# Contract since 2026-08-18: the quota dead-end no longer exempts the watch
# from the CI hold. Waiting cannot clear the quota, but the pending checks
# are the thing that still moves — an immediate return here forced a manual
# `gh pr checks --watch` re-arm after every push (observed twice in one
# session). The UNSATISFIABLE line may only appear once CI has settled, so
# with a permanently-pending stub the watch must run into TIMEOUT without it.
out=$(watch || true)
case "$out" in
    *"ACTIONABLE: request-review (UNSATISFIABLE"*)
        echo "  FAIL quota line fired while CI was unsettled"; fail=1 ;;
    *TIMEOUT*)
        echo "  ok   quota dead-end holds for unsettled CI (timeout)" ;;
    *)  echo "  FAIL unexpected watch output: $(printf '%s' "$out" | head -2)"; fail=1 ;;
esac

echo "case W4: watch + BLOCKED + unsigned + settled — fix-signatures is an actionable event"
MERGE_STATE=BLOCKED SIGNED=0 make_stub "$REAL_REVIEW"
out=$(watch || true)
case "$out" in
    *"ACTIONABLE: fix-signatures"*) echo "  ok   watch returns immediately on the signature gate" ;;
    *TIMEOUT*) echo "  FAIL watch held to timeout on its own headline scenario"; fail=1 ;;
    *) echo "  FAIL unexpected watch output"; fail=1 ;;
esac

# Same hold as W3, reached through the marker instead of an error body: a
# remembered wall changes nothing about the pending checks, so the watch
# keeps waiting for them too.
echo "case W5: watch + pending check + MARKER — holds for CI like W3"
PENDING_CHECK=1 make_stub
plant_marker
out=$(watch || true)
case "$out" in
    *"ACTIONABLE: request-review (UNSATISFIABLE"*)
        echo "  FAIL marker quota line fired while CI was unsettled"; fail=1 ;;
    *TIMEOUT*)
        echo "  ok   remembered quota holds for unsettled CI (timeout)" ;;
    *)  echo "  FAIL unexpected watch output: $(printf '%s' "$out" | head -2)"; fail=1 ;;
esac

# The immediate return the old W3/W5 asserted still exists — one step later.
# Once CI is settled the quota dead-end IS the final state: a re-arm comes
# straight back with the same line, which is what its message warns about.
echo "case W6: watch + settled + QUOTA error — UNSATISFIABLE returns immediately"
make_stub "$ERR_QUOTA"
out=$(watch || true)
case "$out" in
    *"ACTIONABLE: request-review (UNSATISFIABLE"*)
        case "$out" in
            *TIMEOUT*) echo "  FAIL quota line fired only at timeout"; fail=1 ;;
            *) echo "  ok   settled CI + quota returns immediately" ;;
        esac ;;
    *) echo "  FAIL quota line did not fire on settled CI"; fail=1 ;;
esac


# --- Self-review attestation (#203): an explicit author assertion may satisfy
# --- a review demand ONLY where the tool itself calls that demand
# --- unsatisfiable (quota wall, or two failed bot reviews on this head).
SR_MARKER='[{"author": "someone", "body": "Self-review: deadbeefcafe\n\nreviewed by the author, bot unavailable"}]'

echo "case SR1: quota marker + author Self-review comment — gate opens, why names it"
COMMENTS_JSON="$SR_MARKER" make_stub
plant_marker
check "self_review_on_head" "true"  "$(run_flag self_review_on_head)"
check "next.action"         "merge" "$(run_next)"
if status | jq -e '.next.why | test("Self-review attestation")' >/dev/null; then
    echo "  ok   why names the attestation the merge rests on"
else
    echo "  FAIL why does not name the attestation"
    fail=1
fi

echo "case SR2: same comment by a NON-author — attestation not accepted"
COMMENTS_JSON='[{"author": "somebody-else", "body": "Self-review: deadbeefcafe"}]' make_stub
plant_marker
check "self_review_on_head" "false"          "$(run_flag self_review_on_head)"
check "next.action"         "request-review" "$(run_next)"

echo "case SR3: author comment with a STALE sha — dies with the push, as documented"
COMMENTS_JSON='[{"author": "someone", "body": "Self-review: 0ldc0mm1t"}]' make_stub
plant_marker
check "self_review_on_head" "false"          "$(run_flag self_review_on_head)"
check "next.action"         "request-review" "$(run_next)"

echo "case SR4: attestation present but NO quota wall — a live review path wins"
COMMENTS_JSON="$SR_MARKER" make_stub
check "self_review_on_head" "true"           "$(run_flag self_review_on_head)"
check "next.action"         "request-review" "$(run_next)"
case "$(run_flag 'next.cmd')" in
    *"repos/o/r/pulls/1/requested_reviewers"*)
        echo "  ok   the re-request command is still offered — the attestation changed nothing" ;;
    *)  echo "  FAIL the attestation suppressed a live review path"
        fail=1 ;;
esac
check "next.reason absent on the live path" "null" "$(run_flag 'next.reason')"

echo "case SR5: two failed bot reviews + attestation — the two-strikes leg opens too"
COMMENTS_JSON="$SR_MARKER" make_stub "$ERR_GENERIC" "$ERR_GENERIC"
check "copilot_error_count" "2"     "$(run_flag copilot_error_count)"
check "next.action"         "merge" "$(run_next)"

echo "case SR6: prose comment without the marker line — not an attestation (case 8 stays)"
COMMENTS_JSON='[{"author": "someone", "body": "Reviewed this myself, the bot was unavailable."}]' make_stub
plant_marker
check "self_review_on_head" "false"          "$(run_flag self_review_on_head)"
check "next.action"         "request-review" "$(run_next)"

echo "case SR7: quota why advertises the mechanism WITHOUT the accepting sequence"
make_stub
plant_marker
if status | jq -e '.next.why | test("Self-review: <head-sha>")' >/dev/null; then
    echo "  ok   the quota advice names the marker via a placeholder"
else
    echo "  FAIL the quota advice does not describe the marker"
    fail=1
fi
if status | jq -e '.next.why | test("deadbeefcafe")' >/dev/null; then
    echo "  ok   the advice still names the sha to use"
else
    echo "  FAIL the advice lost the sha"
    fail=1
fi
# The paste-safety property this wording exists for: the advice itself, pasted
# into a comment at ANY line wrap, must never contain the accepting sequence.
if status | jq -e '.next.why | test("Self-review: deadbeef")' >/dev/null; then
    echo "  FAIL the advice contains the accepting sequence — a paste could mint an attestation"
    fail=1
else
    echo "  ok   the accepting sequence never appears in the advice"
fi
check "next.reason" "bot-review-unsatisfiable" "$(run_flag 'next.reason')"

echo "case SR8: marker mid-body — the newline leg of the regex"
COMMENTS_JSON='[{"author": "someone", "body": "prelude line\nSelf-review: deadbeefcafe"}]' make_stub
plant_marker
check "self_review_on_head" "true"  "$(run_flag self_review_on_head)"
check "next.action"         "merge" "$(run_next)"

echo "case SR9: blockquoted marker — a quoted paste does not mint an attestation"
COMMENTS_JSON='[{"author": "someone", "body": "> Self-review: deadbeefcafe"}]' make_stub
plant_marker
check "self_review_on_head" "false"          "$(run_flag self_review_on_head)"
check "next.action"         "request-review" "$(run_next)"

echo "case SR10: pending Copilot request outranks the attestation"
COMMENTS_JSON="$SR_MARKER" REVIEW_REQUESTS_JSON='["copilot-pull-request-reviewer[bot]"]' make_stub
plant_marker
check "next.action" "await-review" "$(run_next)"

echo "case SR11: CHANGES_REQUESTED + attestation + quota — a human NO is a live review"
COMMENTS_JSON="$SR_MARKER" REVIEW_DECISION=CHANGES_REQUESTED make_stub
plant_marker
check "next.action" "request-review" "$(run_next)"

if [ "$fail" -eq 0 ]; then
    echo "all pass"
else
    echo "FAILURES"
    exit 1
fi
