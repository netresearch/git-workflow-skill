#!/usr/bin/env bash
# Regression test: required contexts are the UNION of the rules endpoint and
# classic branch protection.
#
# $required was read from repos/:r/rules/branches/:b alone. On a repository
# whose required checks come from classic protection instead, that endpoint
# answers `[]`, so required_contexts and undispatched came back empty, the
# checks rung saw nothing outstanding, and the ladder fell through to
# `investigate — check branch protection manually` with every visible check
# green. That is the question the tool exists to answer.
#
# The fixture is netresearch/orocommerce-skill#20 as measured in #329: no
# ruleset, five required contexts from classic protection, only DCO reporting.
#
# Runs pr-status.sh against a stubbed `gh`, so it needs no network and no repo.

set -euo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/skills/git-workflow/scripts/pr-status.sh"
STUB_DIR="$(mktemp -d)"
trap 'rm -rf "$STUB_DIR"' EXIT

export XDG_CACHE_HOME="$STUB_DIR/cache"

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

# RULES_JSON and PROT_JSON select the case; the GraphQL payload is constant —
# BLOCKED with one green check, which is what the PR page shows when a required
# context never reported.
make_stub() {
    printf '%s\n' "${RULES_JSON}" > "$STUB_DIR/rules.json"
    printf '%s\n' "${PROT_JSON}"  > "$STUB_DIR/prot.json"
    cat > "$STUB_DIR/gh" <<STUB
#!/usr/bin/env bash
for a in "\$@"; do
  case "\$a" in
    repos/*/rules/branches/*)    cat "$STUB_DIR/rules.json"; exit 0 ;;
    repos/*/branches/*/protection)
        if [ -s "$STUB_DIR/prot.json" ] && [ "\$(cat "$STUB_DIR/prot.json")" != "NONE" ]; then
            cat "$STUB_DIR/prot.json"; exit 0
        fi
        exit 1 ;;
  esac
done
cat "$STUB_DIR/graphql.json"
STUB
    chmod +x "$STUB_DIR/gh"
    python3 - "$STUB_DIR/graphql.json" <<'PY'
import sys, json
out = sys.argv[1]
head = "74075602172517f563e654a6ec7c30ba0ceb3b18"
json.dump({"data": {
    "viewer": {"login": "cybot"},
    "repository": {
        "nameWithOwner": "o/r",
        "mergeCommitAllowed": True, "rebaseMergeAllowed": False, "squashMergeAllowed": False,
        "pullRequest": {
            "number": 20, "title": "t", "state": "OPEN", "isDraft": False,
            "mergeable": "MERGEABLE", "mergeStateStatus": "BLOCKED", "reviewDecision": None,
            "author": {"login": "contributor", "__typename": "User"},
            "baseRefName": "main", "headRefName": "f", "headRefOid": head,
            "isCrossRepository": True,
            "comments": {"nodes": []},
            "reviews": {"nodes": [{"author": {"login": "cybot"}, "state": "APPROVED",
                                   "commit": {"oid": head}, "submittedAt": "2026-01-01T00:00:00Z"}]},
            "latestReviews": {"nodes": [{"author": {"login": "cybot"}, "state": "APPROVED",
                                         "commit": {"oid": head}}]},
            "reviewRequests": {"nodes": []},
            "reviewThreads": {"nodes": []},
            "commits": {"nodes": [{"commit": {"oid": head, "statusCheckRollup": {
                "state": "SUCCESS", "contexts": {"nodes": [
                    {"__typename": "StatusContext", "context": "DCO", "state": "SUCCESS",
                     "targetUrl": "u"}]}}}}]},
            "allCommits": {"nodes": [{"commit": {"oid": head,
                                                 "signature": {"isValid": True}}}]},
        }}}}, open(out, "w"))
PY
}

json() { PATH="$STUB_DIR:$PATH" bash "$SCRIPT" -R o/r 20 --json; }
human() { PATH="$STUB_DIR:$PATH" bash "$SCRIPT" -R o/r 20; }

CLASSIC='{"required_status_checks":{"strict":true,"contexts":["Analyze (actions)","validate / Skill Validation","eval / Eval Validation","harness / Verify Harness Consistency","DCO"]},"required_pull_request_reviews":{"required_approving_review_count":0,"dismiss_stale_reviews":true},"required_conversation_resolution":{"enabled":true}}'

echo "case: no ruleset, five required contexts from classic protection"
RULES_JSON='[]' PROT_JSON="$CLASSIC" make_stub
out=$(json)
check "required_contexts counted"  "5" "$(jq -r '.required_contexts | length' <<<"$out")"
check "four never reported"        "4" "$(jq -r '.undispatched | length' <<<"$out")"
check_contains "names a missing one" "Analyze (actions)" "$(jq -r '.undispatched | join(",")' <<<"$out")"
check "DCO is not undispatched"    "false" "$(jq -r '.undispatched | index("DCO") != null' <<<"$out")"

echo "case: the verdict names them instead of sending the reader to the settings page"
hout=$(human || true)
check_contains "not the fall-through" "never reported" "$hout"

echo "case: a ruleset alone still works (the path that already did)"
RULES_JSON='[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"CI"},{"context":"DCO"}]}}]' \
PROT_JSON='NONE' make_stub
out=$(json)
check "required from rules"        "2" "$(jq -r '.required_contexts | length' <<<"$out")"
check "one never reported"         "1" "$(jq -r '.undispatched | length' <<<"$out")"
check_contains "and it is CI"      "CI" "$(jq -r '.undispatched | join(",")' <<<"$out")"

echo "case: both sources — union, deduplicated"
RULES_JSON='[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"DCO"},{"context":"CI"}]}}]' \
PROT_JSON="$CLASSIC" make_stub
out=$(json)
# 5 from classic + CI from the ruleset; DCO appears in both and counts once.
check "union deduplicated"         "6" "$(jq -r '.required_contexts | length' <<<"$out")"
check "five never reported"        "5" "$(jq -r '.undispatched | length' <<<"$out")"

echo "case: neither source — nothing is required, and nothing is invented"
RULES_JSON='[]' PROT_JSON='NONE' make_stub
out=$(json)
check "required empty"             "0" "$(jq -r '.required_contexts | length' <<<"$out")"
check "undispatched empty"         "0" "$(jq -r '.undispatched | length' <<<"$out")"

exit "$fail"
