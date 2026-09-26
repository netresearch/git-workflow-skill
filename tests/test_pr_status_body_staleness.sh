#!/usr/bin/env bash
# After a review round the PR body often still describes the state before it:
# the fix replaced the approach the body explains, and nothing pointed at it.
# pr-status.sh now prints a `body` line when the head commit is newer than the
# last edit of the body (lastEditedAt, or createdAt for a body never edited),
# and carries the same comparison in --json as body_freshness.
#
# The line is information, not a gate: NEXT must read the same whether the
# body is older or newer than the head, so every case asserts next.action too.
#
# Runs against a stubbed `gh`, so it needs no network and no repository.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/skills/git-workflow/scripts/pr-status.sh"
STUB_DIR="$(mktemp -d)"
trap 'rm -rf "$STUB_DIR"' EXIT

fail=0

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

# case <name> <createdAt> <lastEditedAt|null> <committedDate> <line: shown|absent> <older_than_head>
case_() {
  local name="$1" created="$2" edited="$3" committed="$4" line="$5" want="$6"
  python3 - "$STUB_DIR/graphql.json" "$created" "$edited" "$committed" <<'PY'
import sys, json
path, created, edited, committed = sys.argv[1:5]
head = "deadbeefcafe"
json.dump({"data": {"viewer": {"login": "someone"}, "repository": {
    "nameWithOwner": "o/r",
    "mergeCommitAllowed": True, "rebaseMergeAllowed": False, "squashMergeAllowed": False,
    "autoMergeAllowed": True,
    "pullRequest": {
        "number": 7, "title": "t", "state": "OPEN", "isDraft": False,
        "createdAt": created, "lastEditedAt": None if edited == "null" else edited,
        "mergeQueue": None, "mergeQueueEntry": None,
        "mergeable": "MERGEABLE", "mergeStateStatus": "CLEAN", "reviewDecision": "APPROVED",
        "author": {"login": "someone", "__typename": "User"},
        "baseRefName": "main", "headRefName": "f", "headRefOid": head,
        "isCrossRepository": False,
        "comments": {"nodes": []},
        "reviews": {"nodes": [{"author": {"login": "reviewer"}, "state": "APPROVED",
                               "commit": {"oid": head}, "body": ""}]},
        "reviewRequests": {"nodes": []},
        "reviewThreads": {"nodes": []},
        "commits": {"nodes": [{"commit": {"oid": head, "committedDate": committed,
            "statusCheckRollup": {
            "state": "SUCCESS", "contexts": {"nodes": [
                {"__typename": "CheckRun", "name": "CI", "conclusion": "SUCCESS",
                 "status": "COMPLETED", "detailsUrl": "u",
                 "startedAt": "2026-01-01T00:00:00Z"}]}}}}]},
        "allCommits": {"nodes": [{"commit": {"oid": head, "signature": {"isValid": True}}}]},
    }}}}, open(path, "w"))
PY
  local text json got_line got_older got_next
  text="$(PATH="$STUB_DIR:$PATH" bash "$SCRIPT" -R o/r 7)"
  json="$(PATH="$STUB_DIR:$PATH" bash "$SCRIPT" -R o/r 7 --json)"
  if grep -q '^  body        : .* re-read the body against the diff$' <<<"$text"; then
    got_line=shown
  else
    got_line=absent
  fi
  got_older="$(jq -r '.body_freshness.older_than_head' <<<"$json")"
  got_next="$(jq -r '.next.action' <<<"$json")"
  if [[ "$got_line" == "$line" && "$got_older" == "$want" && "$got_next" == "merge" ]]; then
    echo "  ok   $name"
  else
    echo "  FAIL $name: line=$got_line (want $line), older_than_head=$got_older (want $want), next=$got_next (want merge)"
    fail=1
  fi
}

echo "pr-status.sh: PR body older than the head commit"

case_ "body edited before the head commit: line shown" \
      2026-09-01T10:00:00Z 2026-09-02T10:00:00Z 2026-09-03T10:00:00Z shown true
case_ "body edited after the head commit: line absent" \
      2026-09-01T10:00:00Z 2026-09-04T10:00:00Z 2026-09-03T10:00:00Z absent false
# A body nobody edited has lastEditedAt null; createdAt is when it was written.
case_ "never-edited body written before the head commit: line shown" \
      2026-09-01T10:00:00Z null 2026-09-03T10:00:00Z shown true
case_ "never-edited body written after the head commit: line absent" \
      2026-09-04T10:00:00Z null 2026-09-03T10:00:00Z absent false

exit "$fail"
