#!/usr/bin/env bash
# Regression test: pr-status.sh reads CodeRabbit's verdict for the CURRENT head
# out of its single, in-place-edited issue comment — and reports it without
# letting it open the merge gate.
#
# Why this is a test: CodeRabbit never posts a review, so every review-shaped
# field stays empty on a pull request it cleared minutes ago and the report says
# "NONE on current head". An operator who cannot see the verdict either
# re-derives it by hand or writes a self-review note claiming no bot review was
# obtainable when one was. The opposite failure is worse: if the verdict ever
# fed has_review_on_head, a bot comment would clear the gate, so every case here
# asserts that field stays false.
#
# Runs pr-status.sh against a stubbed `gh`, so it needs no network and no repo.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/skills/git-workflow/scripts/pr-status.sh"
STUB_DIR="$(mktemp -d)"
trap 'rm -rf "$STUB_DIR"' EXIT

fail=0
HEAD="a473028eac16e0dbfdf1f28047b4c675f945fbb2"
PREV="4fca1b33fea21e0d3fb4874bebb3f85b8a7c1336"
OLDER="0dcc7ea19bbf0c4a4d1a0bd5c1d0f0e2a3b4c5d6"

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

# $1 = CodeRabbit comment body, or the literal NONE for "the bot never posted"
build_payload() {
    python3 - "$STUB_DIR/graphql.json" "$HEAD" "$1" <<'PY'
import sys, json
out, head, body = sys.argv[1], sys.argv[2], sys.argv[3]
comments = [] if body == "NONE" else [{
    "author": {"login": "coderabbitai[bot]", "__typename": "Bot"},
    "body": body, "url": "u", "createdAt": "2026-01-02T00:00:00Z"}]
json.dump({"data": {"repository": {
    "nameWithOwner": "o/r",
    "mergeCommitAllowed": True, "rebaseMergeAllowed": False, "squashMergeAllowed": False,
    "pullRequest": {
        "number": 1, "title": "t", "state": "OPEN", "isDraft": False,
        "mergeable": "MERGEABLE", "mergeStateStatus": "CLEAN", "reviewDecision": None,
        "author": {"login": "someone"},
        "baseRefName": "main", "headRefName": "f", "headRefOid": head,
        "isCrossRepository": False,
        "comments": {"nodes": comments},
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

run_json() { PATH="$STUB_DIR:$PATH" bash "$SCRIPT" -R o/r 1 --json; }
run_text() { PATH="$STUB_DIR:$PATH" bash "$SCRIPT" -R o/r 1 || true; }

check() { # label expected actual
    if [ "$3" = "$2" ]; then echo "  ok   $1"; else
        echo "  FAIL $1: expected '$2', got '$3'"; fail=1; fi
}

# --- case 1: reviewed clean on THIS head -------------------------------------
# The real shape: the marker sits ABOVE the line naming the range it covers.
echo "case 1: no actionable comments on the current head"
build_payload "No actionable comments were generated in the recent review. 🎉
<details>
Reviewing files that changed from the base of the PR and between $PREV and $HEAD.
</details>"
out="$(run_json)"
check "coderabbit_on_head" "clean" "$(jq -r .coderabbit_on_head <<<"$out")"
check "has_review_on_head stays false" "false" "$(jq -r .has_review_on_head <<<"$out")"
check "next.action is still request-review" "request-review" "$(jq -r .next.action <<<"$out")"
if grep -q 'coderabbit=clean' <<<"$(run_text)"; then
    echo "  ok   the reviews line names the verdict"
else
    echo "  FAIL the reviews line does not name the verdict"; fail=1
fi
if grep -qi 'CodeRabbit reviewed THIS head' <<<"$(jq -r .next.why <<<"$out")"; then
    echo "  ok   next.why names the bot review that exists"
else
    echo "  FAIL next.why does not mention the CodeRabbit verdict"; fail=1
fi

# --- case 2: refused as rate limited on THIS head ----------------------------
echo "case 2: rate limited on the current head"
build_payload "<!-- rate limited by coderabbit.ai -->
Reviewing files that changed from the base of the PR and between $PREV and $HEAD.
<!-- end -->
No actionable comments were generated in the recent review. 🎉
Reviewing files that changed from the base of the PR and between $OLDER and $PREV."
out="$(run_json)"
check "coderabbit_on_head" "rate-limited" "$(jq -r .coderabbit_on_head <<<"$out")"
check "has_review_on_head stays false" "false" "$(jq -r .has_review_on_head <<<"$out")"

# --- case 3: the comment covers an OLDER head only ---------------------------
# The block naming $PREV must not be read as a verdict for $HEAD — this is the
# case that makes "one comment, many blocks" dangerous to grep for a phrase.
echo "case 3: the only block covers an older head"
build_payload "No actionable comments were generated in the recent review. 🎉
Reviewing files that changed from the base of the PR and between $OLDER and $PREV."
out="$(run_json)"
check "coderabbit_on_head" "none" "$(jq -r .coderabbit_on_head <<<"$out")"
if grep -q 'coderabbit=' <<<"$(run_text)"; then
    echo "  FAIL the reviews line claims a verdict for an unreviewed head"; fail=1
else
    echo "  ok   the reviews line stays silent for an unreviewed head"
fi

# --- case 4: actionable comments posted on THIS head -------------------------
echo "case 4: actionable comments on the current head"
build_payload "**Actionable comments posted: 3**
Reviewing files that changed from the base of the PR and between $PREV and $HEAD."
out="$(run_json)"
check "coderabbit_on_head" "findings" "$(jq -r .coderabbit_on_head <<<"$out")"

# --- case 4b: the short-sha shape, which no prefix compare may resolve -------
# "Merge Risk: … up to `2cf7a`" names a head without a range. Five hex digits
# collide, so guessing would report an older assessment as covering this head —
# the one direction that authorises a merge it should not. Must be "unknown".
echo "case 4b: a Merge Risk marker names a short sha and no range"
build_payload "No actionable comments were generated in the recent review. 🎉
**Merge Risk:** _🔵 Low_ · up to \`${HEAD:0:5}\`"
out="$(run_json)"
check "coderabbit_on_head" "unknown" "$(jq -r .coderabbit_on_head <<<"$out")"
check "has_review_on_head stays false" "false" "$(jq -r .has_review_on_head <<<"$out")"
if grep -q 'resolve it with git rev-parse' <<<"$(jq -r .next.why <<<"$out")"; then
    echo "  ok   next.why sends the reader to resolve the short sha"
else
    echo "  FAIL next.why does not explain the short-sha case"; fail=1
fi

# --- case 5: the bot never posted --------------------------------------------
echo "case 5: no CodeRabbit comment at all"
build_payload NONE
out="$(run_json)"
check "coderabbit_on_head" "none" "$(jq -r .coderabbit_on_head <<<"$out")"
check "has_review_on_head stays false" "false" "$(jq -r .has_review_on_head <<<"$out")"

exit $fail
