#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: Netresearch DTT GmbH
# Regression test: a standing review action must not hide a structural merge
# blocker.
#
# Observed on netresearch/netresearch-branding-skill#110 (2026-10-22): a fork
# pull request, mergeStateStatus BLOCKED, every check green, 0 threads. Classic
# protection had required_signatures and 6 of 29 commits were unsigned; the
# required context "All security checks" had not reported on that head; the
# code_scanning rule demanded CodeQL results and CodeQL default setup never ran
# on the fork head. pr-status.sh said only `request-review — Copilot is OUT OF
# REVIEW QUOTA`. The fix-signatures rung that should have fired requires
# checks_settled, which the unreported context made false, and a review
# decision other than REVIEW_REQUIRED.
#
# Runs pr-status.sh against a stubbed `gh`, so it needs no network and no repo.

set -euo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/skills/git-workflow/scripts/pr-status.sh"
STUB_DIR="$(mktemp -d)"
trap 'rm -rf "$STUB_DIR"' EXIT

export XDG_CACHE_HOME="$STUB_DIR/cache"
MARKER="$XDG_CACHE_HOME/pr-status/copilot-quota-exhausted-$(date -u +%Y-%m)"

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

# The quota wall, recorded by an earlier run: what made the review action
# unsatisfiable and therefore standing.
mkdir -p "$(dirname "$MARKER")"
printf 'copilot review quota exhausted; proven on o/r#1 at 2026-01-01T00:00:00Z\n' > "$MARKER"

COPILOT_RULE='{"type":"copilot_code_review","parameters":{}}'
# Copied from repos/netresearch/netresearch-branding-skill/rules/branches/main.
CODEQL_RULE='{"type":"code_scanning","parameters":{"code_scanning_tools":[{"tool":"CodeQL","security_alerts_threshold":"high_or_higher","alerts_threshold":"errors"}]},"ruleset_source_type":"Repository","ruleset_source":"netresearch/netresearch-branding-skill","ruleset_id":25563068}'
SIG_RULE='{"type":"required_signatures"}'
# The classic protection of netresearch-branding-skill main, trimmed to what
# the evaluation reads.
CLASSIC_SIG='{"required_signatures":{"enabled":true},"required_status_checks":{"strict":false,"contexts":["DCO","All security checks"]},"required_pull_request_reviews":{"required_approving_review_count":0,"dismiss_stale_reviews":true}}'

# Environment selects the case:
#   RULES_JSON  rules endpoint answer
#   PROT_JSON   classic protection answer, NONE = unreadable (non-admin caller)
#   RD          reviewDecision ("" = null)
#   CROSS       1 = fork pull request
#   UNSIGNED    1 = six of 29 commits unsigned
#   CODEQL_ROW  1 = a CodeQL check run on the head
make_stub() {
    printf '%s\n' "${RULES_JSON}" > "$STUB_DIR/rules.json"
    printf '%s\n' "${PROT_JSON}"  > "$STUB_DIR/prot.json"
    cat > "$STUB_DIR/gh" <<STUB
#!/usr/bin/env bash
for a in "\$@"; do
  case "\$a" in
    repos/*/rules/branches/*) cat "$STUB_DIR/rules.json"; exit 0 ;;
    repos/*/branches/*/protection)
        if [ "\$(cat "$STUB_DIR/prot.json")" != "NONE" ]; then
            cat "$STUB_DIR/prot.json"; exit 0
        fi
        echo "gh: Not Found (HTTP 404)" >&2; exit 1 ;;
    repos/*/actions/runs*) echo '{"workflow_runs":[]}'; exit 0 ;;
  esac
done
cat "$STUB_DIR/graphql.json"
STUB
    chmod +x "$STUB_DIR/gh"
    python3 - "$STUB_DIR/graphql.json" <<'PY'
import sys, json, os
out = sys.argv[1]
head = "0419d32f1833c9b81e1f3d197e03de57ff03313e"
unsigned = os.environ.get("UNSIGNED", "1") == "1"
commits = []
for i in range(29):
    oid = head if i == 28 else ("%08x" % (0x10000000 + i)) + "b" * 32
    signed = not (unsigned and i in (3, 7, 11, 15, 19, 23))
    # The viewer pushed fixes onto the contributor branch, as on #110.
    login = "cybot" if i >= 20 else "contributor"
    commits.append({"commit": {"oid": oid,
        "signature": {"isValid": True} if signed else None,
        "parents": {"totalCount": 1},
        "authors": {"totalCount": 1, "nodes": [{"user": {"login": login}}]}}})
def run(name):
    return {"__typename": "CheckRun", "name": name, "conclusion": "SUCCESS",
            "status": "COMPLETED", "detailsUrl": "u", "startedAt": "2026-10-20T10:31:25Z",
            "steps": {"totalCount": 3}, "annotations": {"nodes": []},
            "checkSuite": {"status": "COMPLETED", "workflowRun": None}}
contexts = [{"__typename": "StatusContext", "context": "DCO", "state": "SUCCESS", "targetUrl": "u"},
            run("Skill Validation / Skill Validation")]
if os.environ.get("CODEQL_ROW", "0") == "1":
    contexts += [run("CodeQL"), run("Analyze (python)")]
json.dump({"data": {
  "viewer": {"login": "cybot"},
  "repository": {
    "nameWithOwner": "o/r",
    "mergeCommitAllowed": True, "rebaseMergeAllowed": False, "squashMergeAllowed": False,
    "pullRequest": {
        "number": 110, "title": "t", "state": "OPEN", "isDraft": False,
        "mergeable": "MERGEABLE", "mergeStateStatus": "BLOCKED",
        "reviewDecision": os.environ.get("RD") or None,
        "author": {"login": "contributor", "__typename": "User"},
        "baseRefName": "main", "headRefName": "f", "headRefOid": head,
        "isCrossRepository": os.environ.get("CROSS", "1") == "1",
        "comments": {"nodes": []},
        "reviews": {"nodes": []},
        "reviewRequests": {"nodes": []},
        "reviewThreads": {"nodes": []},
        "commits": {"nodes": [{"commit": {"oid": head, "committedDate": "2026-10-20T10:23:37Z",
            "statusCheckRollup": {"state": "SUCCESS", "contexts": {
                "pageInfo": {"hasNextPage": False}, "nodes": contexts}}}}]},
        "allCommits": {"totalCount": 29, "nodes": commits},
    }}}}, open(out, "w"))
PY
}

json() { PATH="$STUB_DIR:$PATH" bash "$SCRIPT" -R o/r 110 --json; }
action() { jq -r '.next.action' <<<"$1"; }
why() { jq -r '.next.why' <<<"$1"; }

echo "case: #110 — quota wall, unsigned commits under classic required_signatures, unreported context, fork without CodeQL"
RULES_JSON="[$COPILOT_RULE,$CODEQL_RULE]" PROT_JSON="$CLASSIC_SIG" RD="" CROSS=1 UNSIGNED=1 CODEQL_ROW=0 make_stub
out=$(json)
check          "the signatures lead"            "fix-signatures" "$(action "$out")"
check_contains "names the source"               "classic branch protection requires signed commits" "$(why "$out")"
check_contains "names the six commits"          "6 commit(s)" "$(why "$out")"
check_contains "keeps the review gate in sight" "The review gate is open as well" "$(why "$out")"
check_contains "names the unreported context"   "never reported on 0419d32f — All security checks" "$(why "$out")"
check_contains "names the CodeQL fork gap"      "CodeQL default setup never analyzes fork pull requests" "$(why "$out")"
check_contains "points to the workaround"       "merge-strategy.md" "$(why "$out")"

echo "case: the same with REVIEW_REQUIRED — a known requirement still leads"
RULES_JSON="[$COPILOT_RULE]" PROT_JSON="$CLASSIC_SIG" RD="REVIEW_REQUIRED" CROSS=1 UNSIGNED=1 CODEQL_ROW=0 make_stub
out=$(json)
check          "fix-signatures"                 "fix-signatures" "$(action "$out")"
check_contains "names the decision"             "decision REVIEW_REQUIRED" "$(why "$out")"

echo "case: the ruleset form of the requirement, protection unreadable"
RULES_JSON="[$COPILOT_RULE,$SIG_RULE]" PROT_JSON="NONE" RD="REVIEW_REQUIRED" CROSS=1 UNSIGNED=1 CODEQL_ROW=0 make_stub
out=$(json)
check          "fix-signatures"                 "fix-signatures" "$(action "$out")"
check_contains "names the ruleset"              "the required_signatures ruleset requires signed commits" "$(why "$out")"

# The control for #187's guard: with the requirement unknown (protection
# unreadable, no ruleset) and a host-required review, unsigned commits are a
# suspect, not a fact, and an author who does not sign must not be handed a
# history rewrite for a review problem.
echo "case: requirement unknown and REVIEW_REQUIRED — the review action stands"
RULES_JSON="[$COPILOT_RULE]" PROT_JSON="NONE" RD="REVIEW_REQUIRED" CROSS=1 UNSIGNED=1 CODEQL_ROW=0 make_stub
out=$(json)
check          "request-review"                 "request-review" "$(action "$out")"
check_absent   "no signature claim"             "signed commits" "$(why "$out")"

echo "case: every commit signed — no signature claim, the review action stands"
RULES_JSON="[$COPILOT_RULE,$CODEQL_RULE]" PROT_JSON="$CLASSIC_SIG" RD="" CROSS=1 UNSIGNED=0 CODEQL_ROW=0 make_stub
out=$(json)
check          "request-review"                 "request-review" "$(action "$out")"
check_absent   "no signature claim"             "carry no valid signature" "$(why "$out")"
check_contains "but the CodeQL gap is named"    "CodeQL default setup never analyzes fork pull requests" "$(why "$out")"
check_contains "and the unreported context"     "All security checks" "$(why "$out")"

echo "case: same-repository pull request — no CodeQL fork claim"
RULES_JSON="[$COPILOT_RULE,$CODEQL_RULE]" PROT_JSON="$CLASSIC_SIG" RD="" CROSS=0 UNSIGNED=0 CODEQL_ROW=0 make_stub
out=$(json)
check_absent   "no fork claim"                  "CodeQL default setup" "$(why "$out")"

echo "case: fork with a CodeQL row on the head — no CodeQL fork claim"
RULES_JSON="[$COPILOT_RULE,$CODEQL_RULE]" PROT_JSON="$CLASSIC_SIG" RD="" CROSS=1 UNSIGNED=0 CODEQL_ROW=1 make_stub
out=$(json)
check_absent   "no fork claim"                  "CodeQL default setup" "$(why "$out")"

exit "$fail"
