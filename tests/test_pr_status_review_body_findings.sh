#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: Netresearch DTT GmbH
# CodeRabbit puts some findings into the BODY of a review, under a collapsible
# section summarised "Additional comments: N", instead of into a thread. They
# never become reviewThreads, so pr-status.sh printed "threads: 0 unresolved"
# and NEXT=merge on netresearch/moodle-docker#109 while review 5879112466
# carried a Major finding on docker/moodle/Dockerfile line 64.
#
# pr-status.sh now prints a `review body` line per such review, lists them in
# --json as review_body_findings, and answers address-comments until the
# author or the viewer has commented after the review.
#
# The review bodies are real, copied from the API into
# tests/fixtures/coderabbit-review-body/ (bodies verbatim, other fields
# trimmed). Runs against a stubbed `gh`, so it needs no network.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/skills/git-workflow/scripts/pr-status.sh"
FIX="$ROOT/tests/fixtures/coderabbit-review-body"
STUB_DIR="$(mktemp -d)"
trap 'rm -rf "$STUB_DIR"' EXIT

fail=0
ran=0

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

# stub <fixture> <head-sha> <comments-json> [login-override]
# The fixture's reviews are turned into the GraphQL shape: the login loses the
# [bot] suffix REST appends, and the REST user type becomes __typename. The
# head is the PR head, which may be a later commit than the review's.
# comments-json is a list of [login, createdAt].
stub() {
  local fixture="$1" head="$2" comments="$3" login_override="${4:-}"
  python3 - "$STUB_DIR/graphql.json" "$FIX/$fixture" "$head" "$comments" "$login_override" <<'PY'
import sys, json
path, fixture, head, comments, login_override = sys.argv[1:6]
reviews = [{"author": {"login": login_override or r["login"].removesuffix("[bot]"),
                       "__typename": "User" if login_override else r["type"]},
            "state": "COMMENTED", "commit": {"oid": r["commit_id"]}, "body": r["body"],
            "databaseId": r["id"], "url": r["html_url"], "submittedAt": r["submitted_at"]}
           for r in json.load(open(fixture))["reviews"]]
reviews.append({"author": {"login": "reviewer", "__typename": "User"}, "state": "APPROVED",
                "commit": {"oid": head}, "body": "", "databaseId": 1, "url": "u",
                "submittedAt": "2026-11-12T23:00:00Z"})
nodes = [{"author": {"login": login, "__typename": "User"}, "body": "x", "url": "u",
          "createdAt": created, "lastEditedAt": None}
         for login, created in json.loads(comments)]
json.dump({"data": {"viewer": {"login": "someone"}, "repository": {
    "nameWithOwner": "o/r",
    "mergeCommitAllowed": True, "rebaseMergeAllowed": False, "squashMergeAllowed": False,
    "autoMergeAllowed": True,
    "pullRequest": {
        "number": 7, "title": "t", "state": "OPEN", "isDraft": False,
        "createdAt": "2026-11-12T10:00:00Z", "lastEditedAt": "2026-11-12T23:30:00Z",
        "mergeQueue": None, "mergeQueueEntry": None,
        "mergeable": "MERGEABLE", "mergeStateStatus": "CLEAN", "reviewDecision": "APPROVED",
        "author": {"login": "someone", "__typename": "User"},
        "baseRefName": "main", "headRefName": "f", "headRefOid": head,
        "isCrossRepository": False,
        "comments": {"nodes": nodes},
        "reviews": {"nodes": reviews},
        "reviewRequests": {"nodes": []},
        "reviewThreads": {"nodes": []},
        "commits": {"nodes": [{"commit": {"oid": head, "committedDate": "2026-11-12T22:00:00Z",
            "statusCheckRollup": {
            "state": "SUCCESS", "contexts": {"pageInfo": {"hasNextPage": False}, "nodes": [
                {"__typename": "CheckRun", "name": "CI", "conclusion": "SUCCESS",
                 "status": "COMPLETED", "detailsUrl": "u",
                 "startedAt": "2026-11-12T22:00:00Z"}]}}}}]},
        "allCommits": {"nodes": [{"commit": {"oid": head, "signature": {"isValid": True}}}]},
    }}}}, open(path, "w"))
PY
}

# case_ <name> <want-next> <want-findings-json> <want-line-or-"-">
# want-findings-json is the expected .review_body_findings reduced to
# [{review_id, commit7, count, answered}]; "-" as want-line means no
# `review body` line may appear.
case_() {
  local name="$1" want_next="$2" want_findings="$3" want_line="$4"
  local text json got_next got_findings ok=1
  ran=$((ran + 1))
  text="$(PATH="$STUB_DIR:$PATH" bash "$SCRIPT" -R o/r 7)"
  json="$(PATH="$STUB_DIR:$PATH" bash "$SCRIPT" -R o/r 7 --json)"
  got_next="$(jq -r '.next.action' <<<"$json")"
  got_findings="$(jq -c '[.review_body_findings[] | {review_id, commit7: .commit[0:7], count, answered}]' <<<"$json")"
  [[ "$got_next" == "$want_next" ]] || ok=0
  [[ "$got_findings" == "$(jq -c . <<<"$want_findings")" ]] || ok=0
  if [[ "$want_line" == "-" ]]; then
    ! grep -q '^  review body : ' <<<"$text" || ok=0
  else
    grep -qxF "$want_line" <<<"$text" || ok=0
  fi
  grep -qxF '  threads     : 0 unresolved' <<<"$text" || ok=0
  if [[ "$ok" == 1 ]]; then
    echo "  ok   $name"
  else
    echo "  FAIL $name: next=$got_next (want $want_next), findings=$got_findings (want $want_findings)"
    grep '^  review body : \|^NEXT' <<<"$text" | sed 's/^/         /' || :
    fail=1
  fi
}

echo "pr-status.sh: findings in a CodeRabbit review body, outside threads"

# Case 1 is the PR that motivated this: the finding sits in the review of
# 6206543, and the PR head is the later 03a1c5f, whose own CodeRabbit review
# has an empty body. Head-only scanning would miss it.
stub moodle-docker-109.json 03a1c5fbc447dfe2ae1469f614b0017f4de293b4 '[]'
case_ "moodle-docker#109 verbatim: Additional comments: 1 on an older commit" \
      address-comments '[{"review_id":5879112466,"commit7":"6206543","count":1,"answered":false}]' \
      '  review body : coderabbitai 1 additional comment(s) outside threads (review 5879112466, commit 6206543)'

stub moodle-docker-109.json 03a1c5fbc447dfe2ae1469f614b0017f4de293b4 \
     '[["someone", "2026-11-12T17:00:00Z"]]'
case_ "an author comment BEFORE the review does not answer it" \
      address-comments '[{"review_id":5879112466,"commit7":"6206543","count":1,"answered":false}]' \
      '  review body : coderabbitai 1 additional comment(s) outside threads (review 5879112466, commit 6206543)'

stub moodle-docker-109.json 03a1c5fbc447dfe2ae1469f614b0017f4de293b4 \
     '[["someone", "2026-11-12T17:40:00Z"]]'
case_ "an author comment after the review answers it: merge, line still shown" \
      merge '[{"review_id":5879112466,"commit7":"6206543","count":1,"answered":true}]' \
      '  review body : coderabbitai 1 additional comment(s) outside threads (review 5879112466, commit 6206543) — answered after the review'

# The older summary shape with an emoji in front, two findings in one section.
stub coding_agent_cli_toolset-187.json ce45c7d972a200861eb485ba9d00972e3db5bcf8 '[]'
case_ "coding_agent_cli_toolset#187 verbatim: emoji-prefixed Additional comments: 2" \
      address-comments '[{"review_id":5681828678,"commit7":"ce45c7d","count":2,"answered":false}]' \
      '  review body : coderabbitai 2 additional comment(s) outside threads (review 5681828678, commit ce45c7d)'

# Negative cases: real CodeRabbit reviews with findings only in threads
# ("Actionable comments posted: 3") and no body section of that kind.
stub moodle-docker-112.json 96e366f6db62027cef3a7e533fc11aa1a3fefdce '[]'
case_ "moodle-docker#112 verbatim: no body section, NEXT stays merge" merge '[]' -

stub moodle-docker-113.json b92ba5aaa7c1f2c757d945a05f8e7b3622a1cb69 '[]'
case_ "moodle-docker#113 verbatim: no body section, NEXT stays merge" merge '[]' -

# A person whose login merely starts with coderabbitai does not speak for it.
stub moodle-docker-109.json 03a1c5fbc447dfe2ae1469f614b0017f4de293b4 '[]' coderabbitai-fan
case_ "a User account named like the bot is ignored" merge '[]' -

[[ "$ran" == 7 ]] || { echo "  FAIL ran $ran of 7 cases"; fail=1; }
exit "$fail"
