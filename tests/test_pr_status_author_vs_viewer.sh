#!/usr/bin/env bash
# Regression test: the self-review attestation is an assertion BY THE AUTHOR, so
# it is unavailable to anyone else — not only to a bot (#280), but to any
# operator finishing a pull request they did not author. pr-merge.sh
# --self-reviewed refuses every non-author, so recommending it to one
# recommends an action that cannot succeed.
#
# Measured on netresearch/concourse-ci-skill#57: author aseemann, viewer
# CybotTM, both human. Every read printed the attestation advice, it was
# relayed to the operator twice, and pr-merge.sh refused it at merge time. The
# ordinary path — a real APPROVED review, which a non-author CAN give — was
# open the whole time and went unnamed.
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
MARKER="$XDG_CACHE_HOME/pr-status/copilot-quota-exhausted-$(date -u +%Y-%m)"

arm_marker() {
    mkdir -p "$(dirname "$MARKER")"
    printf 'copilot review quota exhausted; proven on o/r#1 at 2026-01-01T00:00:00Z\n' > "$MARKER"
}

# Stub `gh`: repo demands a Copilot review, nothing has reviewed this head, and
# the quota wall is armed — the state in which the advice is emitted.
# AUTHOR / VIEWER / AUTHOR_TYPENAME select the case under test.
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
author = os.environ.get("AUTHOR", "someone")
viewer = os.environ.get("VIEWER", "someone")
typename = os.environ.get("AUTHOR_TYPENAME", "User")
json.dump({"data": {
    "viewer": {"login": viewer},
    "repository": {
        "nameWithOwner": "o/r",
        "mergeCommitAllowed": True, "rebaseMergeAllowed": False, "squashMergeAllowed": False,
        "pullRequest": {
            "number": 1, "title": "t", "state": "OPEN", "isDraft": False,
            "mergeable": "MERGEABLE", "mergeStateStatus": "BLOCKED", "reviewDecision": None,
            "author": {"login": author, "__typename": typename},
            "baseRefName": "main", "headRefName": "f", "headRefOid": head,
            "isCrossRepository": False,
            "comments": {"nodes": []},
            "reviews": {"nodes": []},
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

# The attestation is the author's to post, so it stays the advice here. This is
# the case the fix must NOT disturb.
echo "case: viewer IS the author -> attestation advice stands"
AUTHOR=someone VIEWER=someone make_stub; arm_marker
out=$(status)
check_contains "attestation named"   "To proceed on a documented self-review" "$out"
check_absent   "approve not pushed"  "--approve"        "$out"

# The case this test exists for.
echo "case: viewer is NOT the author (both human) -> approve, never the attestation"
AUTHOR=aseemann VIEWER=cybot make_stub; arm_marker
out=$(status)
check_contains "approve named"         "gh pr review 1 --repo o/r --approve" "$out"
check_contains "non-authorship stated" "not by you (cybot)"                  "$out"
check_absent   "attestation withdrawn" "To proceed on a documented self-review" "$out"
check_absent   "not offered as the command" "satisfies it: pr-merge.sh --self-reviewed" "$out"

# #280: a bot author reaches the same advice by the other half of the predicate.
echo "case: bot author -> approve (regression, #280)"
AUTHOR="renovate" AUTHOR_TYPENAME="Bot" VIEWER=cybot make_stub; arm_marker
out=$(status)
check_contains "approve named"       "gh pr review 1 --repo o/r --approve" "$out"
check_contains "bot reason retained" "never reads a diff"                  "$out"
check_absent   "attestation absent"  "To proceed on a documented self-review" "$out"

# An older gh, or any stubbed response without a viewer, must keep the previous
# behaviour rather than silently withdrawing the attestation advice.
echo "case: viewer absent -> falls back to the attestation advice"
AUTHOR=someone VIEWER="" make_stub; arm_marker
out=$(status)
check_contains "attestation named" "To proceed on a documented self-review" "$out"

exit "$fail"
