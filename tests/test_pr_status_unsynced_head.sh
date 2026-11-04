#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: Netresearch DTT GmbH
# A push can land on the branch while the pull request keeps showing the old
# head: GitHub accepted the ref update but never processed it for the PR, and
# no workflow ran for the new commit. pr-status.sh then judged the OLD head and
# answered `ready` / `merge` for a state that no longer existed
# (netresearch/typo3-core-contributions-skill#108, 2026-11-04: branch at
# 4c3a415, PR head 465042a, zero runs for 4c3a415 after five minutes).
#
# Run inside a checkout of the PR's head branch, pr-status.sh now compares the
# local HEAD with the PR head:
#   - pushed but not on the PR  -> NEXT is `wait`, naming both commits and the
#                                  re-push that fixes a lost push event;
#   - not pushed yet            -> NEXT unchanged, a note says the verdict
#                                  covers the pushed head only;
#   - same commit, other branch -> nothing changes.
#
# Runs against a stubbed `gh` and a local bare repository standing in for the
# GitHub remote, so it needs no network.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/skills/git-workflow/scripts/pr-status.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail=0
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.org
export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.org

mkdir -p "$WORK/stub" "$WORK/remote/o"
printf '%s\n' '[]' > "$WORK/rules.json"
cat > "$WORK/stub/gh" <<STUB
#!/usr/bin/env bash
for a in "\$@"; do
  case "\$a" in
    repos/*/rules/branches/*) cat "$WORK/rules.json"; exit 0 ;;
  esac
done
cat "$WORK/graphql.json"
STUB
chmod +x "$WORK/stub/gh"

# The remote's path ends in o/r.git, as a GitHub URL for -R o/r would.
git init -q --bare "$WORK/remote/o/r.git"
git init -q -b f "$WORK/clone"
git -C "$WORK/clone" remote add origin "$WORK/remote/o/r.git"
git -C "$WORK/clone" commit -q --allow-empty -m one
git -C "$WORK/clone" push -q origin f
FIRST="$(git -C "$WORK/clone" rev-parse HEAD)"

# graphql <head oid> — a clean, approved, green PR whose head is <head oid>.
graphql() {
  python3 - "$WORK/graphql.json" "$1" <<'PY'
import sys, json
path, head = sys.argv[1:3]
json.dump({"data": {"viewer": {"login": "someone"}, "repository": {
    "nameWithOwner": "o/r",
    "mergeCommitAllowed": True, "rebaseMergeAllowed": False, "squashMergeAllowed": False,
    "autoMergeAllowed": True,
    "pullRequest": {
        "number": 7, "title": "t", "state": "OPEN", "isDraft": False,
        "createdAt": "2026-11-04T10:00:00Z", "lastEditedAt": None,
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
        "commits": {"nodes": [{"commit": {"oid": head, "committedDate": "2026-11-04T09:00:00Z",
            "statusCheckRollup": {
            "state": "SUCCESS", "contexts": {"pageInfo": {"hasNextPage": False}, "nodes": [
                {"__typename": "CheckRun", "name": "CI", "conclusion": "SUCCESS",
                 "status": "COMPLETED", "detailsUrl": "u",
                 "startedAt": "2026-11-04T09:00:00Z"}]}}}}]},
        "allCommits": {"nodes": [{"commit": {"oid": head, "signature": {"isValid": True}}}]},
    }}}}, open(path, "w"))
PY
}

# check <name> <want action> <jq predicate on the --json output>
check() {
  local name="$1" want="$2" pred="$3" json got
  json="$(cd "$WORK/clone" && PATH="$WORK/stub:$PATH" bash "$SCRIPT" -R o/r 7 --json)"
  got="$(jq -r '.next.action' <<<"$json")"
  if [[ "$got" == "$want" ]] && jq -e "$pred" <<<"$json" >/dev/null; then
    echo "  ok   $name"
  else
    echo "  FAIL $name: next=$got (want $want); next=$(jq -c '.next' <<<"$json")"
    fail=1
  fi
}

echo "pr-status.sh: local HEAD against the PR head"

graphql "$FIRST"
check "local HEAD is the PR head: unchanged" merge \
      '(.next.why | test("not processed") | not) and (.next.note // "" | test("not pushed") | not)'

git -C "$WORK/clone" commit -q --allow-empty -m two
SECOND="$(git -C "$WORK/clone" rev-parse HEAD)"
check "local commit not pushed yet: verdict kept, note added" merge \
      '.next.note | test("not pushed") and test("'"${SECOND:0:8}"'")'

git -C "$WORK/clone" push -q origin f
check "pushed but the PR still shows the old head: wait" wait \
      '(.next.why | test("not processed") and test("'"${SECOND:0:8}"'") and test("'"${FIRST:0:8}"'"))
       and (.next.cmd | test("--force-with-lease"))'

git -C "$WORK/clone" checkout -q -b other
check "a different branch is checked out: unchanged" merge \
      '(.next.why | test("not processed") | not) and (.next.note // "" | test("not pushed") | not)'

exit "$fail"
