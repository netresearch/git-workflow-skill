#!/usr/bin/env bash
# Regression test: prose written under a pull request must not be invisible.
#
# A reviewer who comments under the PR rather than on a line of the diff
# produces an ISSUE comment. It appears in neither reviewThreads nor the check
# rollup, so a report built from those alone says "threads: 0 unresolved" while
# the findings sit unread. Observed on phpDocumentor/guides#1352 (2026-08-28):
# three comments waiting, two of them substantive, reported as nothing open.
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
contains() { # contains <name> <needle> <haystack>
    case "$3" in
        *"$2"*) echo "  ok   $1" ;;
        *) echo "  FAIL $1: '$2' not found in output"; fail=1 ;;
    esac
}
lacks() { # lacks <name> <needle> <haystack>
    case "$3" in
        *"$2"*) echo "  FAIL $1: '$2' should not appear"; fail=1 ;;
        *) echo "  ok   $1" ;;
    esac
}

# COMMENTS_JSON is [{"author":…,"body":…,"createdAt":…}]. createdAt is what
# separates answered from unanswered, so it is never defaulted here: a comment
# without one would silently compare as older than everything and the whole
# test would pass against a script that does nothing.
make_stub() {
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
    python3 - "$STUB_DIR/graphql.json" <<'PY'
import sys, json, os
out = sys.argv[1]
head = "deadbeefcafe"
comments = [{"author": {"login": c["author"],
                        "__typename": c.get("type", "User")},
             "body": c.get("body", "x"),
             "url": "https://example.test/c", "createdAt": c["createdAt"]}
            for c in json.loads(os.environ["COMMENTS_JSON"])]
json.dump({"data": {"repository": {
    "nameWithOwner": "o/r",
    "mergeCommitAllowed": True, "rebaseMergeAllowed": False, "squashMergeAllowed": False,
    "pullRequest": {
        "number": 1, "title": "t", "state": "OPEN", "isDraft": False,
        "mergeable": "MERGEABLE", "mergeStateStatus": "CLEAN", "reviewDecision": None,
        "author": {"login": "author"},
        "baseRefName": "main", "headRefName": "f", "headRefOid": head,
        "isCrossRepository": False,
        "comments": {"nodes": comments},
        "reviews": {"nodes": [{"author": {"login": "reviewer"}, "state": "APPROVED",
                               "commit": {"oid": head}, "body": "lgtm"}]},
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

run() { PATH="$STUB_DIR:$PATH" "$SCRIPT" -R o/r 1 2>&1; }
action() { PATH="$STUB_DIR:$PATH" "$SCRIPT" -R o/r 1 --json 2>/dev/null | jq -r .next.action; }

echo "Case 1: a maintainer comment newer than the last word of the author"
COMMENTS_JSON='[{"author":"author","createdAt":"2026-08-01T10:00:00Z"},
                {"author":"linawolf","createdAt":"2026-08-02T10:00:00Z"}]' make_stub
out="$(run)"
check   "NEXT is address-comments" "address-comments" "$(action)"
contains "report names the commenter" "1 unanswered (linawolf)" "$out"

echo "Case 2: the author answered afterwards"
COMMENTS_JSON='[{"author":"linawolf","createdAt":"2026-08-02T10:00:00Z"},
                {"author":"author","createdAt":"2026-08-03T10:00:00Z"}]' make_stub
out="$(run)"
check "answered comments do not drive NEXT" "merge" "$(action)"
lacks "no comments line once answered" "unanswered" "$out"

echo "Case 3: a bot comment is reported but never gates"
COMMENTS_JSON='[{"author":"renovate[bot]","createdAt":"2026-08-02T10:00:00Z"}]' make_stub
out="$(run)"
check    "a bot must not push its own PR off the merge rung" "merge" "$(action)"
contains "bot comment is still visible"  "bots only, not gating" "$out"

echo "Case 3b: an App whose login carries no [bot] suffix"
# GraphQL returns Bot for an App and strips the [bot] suffix that REST appends,
# so logins like github-actions and sonarqubecloud read as people to a login
# test. Measured on netresearch/git-workflow-skill#252, where exactly this took
# the PR off the merge rung.
COMMENTS_JSON='[{"author":"sonarqubecloud","type":"Bot","createdAt":"2026-08-02T10:00:00Z"}]' make_stub
out="$(run)"
check    "__typename Bot outranks a human-looking login" "merge" "$(action)"
contains "the App comment is still visible" "bots only, not gating" "$out"

echo "Case 4: the author never commented at all"
COMMENTS_JSON='[{"author":"jaapio","createdAt":"2026-08-02T10:00:00Z"}]' make_stub
check "silence by the author does not mean answered" "address-comments" "$(action)"

echo "Case 5: an open review thread stays the more specific answer"
COMMENTS_JSON='[{"author":"linawolf","createdAt":"2026-08-02T10:00:00Z"}]' make_stub
python3 - "$STUB_DIR/graphql.json" <<'PY'
import sys, json
p = sys.argv[1]
d = json.load(open(p))
d["data"]["repository"]["pullRequest"]["reviewThreads"]["nodes"] = [
    {"id": "T1", "isResolved": False, "isOutdated": False,
     "comments": {"nodes": [{"databaseId": 9, "author": {"login": "linawolf"},
                             "path": "src/x.php"}]}}]
json.dump(d, open(p, "w"))
PY
check "threads outrank loose comments" "resolve-threads" "$(action)"

[ "$fail" = "0" ] && echo "All cases passed." || echo "FAILURES"
exit "$fail"
