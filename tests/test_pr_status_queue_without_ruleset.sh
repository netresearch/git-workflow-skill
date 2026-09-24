#!/usr/bin/env bash
# A merge queue set up through classic branch protection has no ruleset, so the
# rules endpoint never lists it. queue_active used to come from the rule types
# alone, read false for such a repository, and pr-merge.sh then passed
# --delete-branch into a queue that refuses it: "Cannot use `-d` or
# `--delete-branch` when merge queue enabled" (glpi-docker-compose-stack#41).
#
# The mergeQueue field of the pull request answers directly: GitHub resolves it
# for the PR's base branch, so a classic queue on a release branch is seen as
# well. Both directions are asserted, and the rule-based path must keep working
# on its own.
#
# Runs against a stubbed `gh`, so it needs no network and no repository.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/skills/git-workflow/scripts/pr-status.sh"
STUB_DIR="$(mktemp -d)"
trap 'rm -rf "$STUB_DIR"' EXIT

fail=0

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

# case <name> <rules-json> <PR mergeQueue: yes|no> <base> <expected queue_active>
case_() {
  local name="$1" rules="$2" mq="$3" base="$4" want="$5" got
  printf '%s\n' "$rules" > "$STUB_DIR/rules.json"
  python3 - "$STUB_DIR/graphql.json" "$mq" "$base" <<'PY'
import sys, json
path, mq, base = sys.argv[1], sys.argv[2], sys.argv[3]
head = "deadbeefcafe"
json.dump({"data": {"viewer": {"login": "someone"}, "repository": {
    "nameWithOwner": "o/r",
    "mergeCommitAllowed": True, "rebaseMergeAllowed": True, "squashMergeAllowed": False,
    "autoMergeAllowed": True,
    "pullRequest": {
        "number": 41, "title": "t", "state": "OPEN", "isDraft": False,
        "mergeQueue": {"id": "MQ_x"} if mq == "yes" else None,
        "mergeable": "MERGEABLE", "mergeStateStatus": "CLEAN", "reviewDecision": "APPROVED",
        "mergeQueueEntry": None,
        "author": {"login": "someone", "__typename": "User"},
        "baseRefName": base, "headRefName": "f", "headRefOid": head,
        "isCrossRepository": False,
        "comments": {"nodes": []},
        "reviews": {"nodes": [{"author": {"login": "reviewer"}, "state": "APPROVED",
                               "commit": {"oid": head}, "body": ""}]},
        "reviewRequests": {"nodes": []},
        "reviewThreads": {"nodes": []},
        "commits": {"nodes": [{"commit": {"oid": head, "statusCheckRollup": {
            "state": "SUCCESS", "contexts": {"nodes": [
                {"__typename": "CheckRun", "name": "CI", "conclusion": "SUCCESS",
                 "status": "COMPLETED", "detailsUrl": "u",
                 "startedAt": "2026-01-01T00:00:00Z"}]}}}}]},
        "allCommits": {"nodes": [{"commit": {"oid": head, "signature": {"isValid": True}}}]},
    }}}}, open(path, "w"))
PY
  got="$(PATH="$STUB_DIR:$PATH" bash "$SCRIPT" -R o/r 41 --json | jq -r '.queue_active')"
  if [[ "$got" == "$want" ]]; then
    echo "  ok   $name"
  else
    echo "  FAIL $name: queue_active=$got, expected $want"; fail=1
  fi
}

echo "pr-status.sh: merge queue without a ruleset"

# The shape glpi-docker-compose-stack#41 had: no rules at all, a queue on main.
case_ "classic-protection queue on the default branch is seen" '[]' yes main true
case_ "no ruleset and no queue reads false" '[]' no main false
case_ "a merge_queue rule alone still counts" \
      '[{"type":"merge_queue","parameters":{}}]' no main true
# A classic queue protecting a release branch: the PR into it goes through it.
case_ "classic-protection queue on a non-default base is seen" '[]' yes release/1.x true
# No queue on the PR's base, whatever other branches have.
case_ "no queue on this base reads false" '[]' no release/1.x false

exit "$fail"
