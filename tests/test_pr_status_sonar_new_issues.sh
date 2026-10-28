#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: Netresearch DTT GmbH
# A passed SonarCloud Quality Gate can still list new issues: the default gate
# fails on ratings, coverage and duplication, not on the issue count. On
# netresearch/data-tools-skill#97 the comment read "Quality Gate passed" with
# "[1 New issue]", every check was green, and the finding stood open on main
# after the merge. pr-status.sh now prints a `sonar` line when the newest
# SonarCloud comment counts new issues, and carries the count in --json as
# sonar_new_issues.
#
# The line is information, not a gate: NEXT must read "merge" in every case.
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

# The comment body of netresearch/data-tools-skill#97, copied verbatim except
# for the two trailing spaces of each Markdown line break, which are left
# out; the count does not depend on them.
cat > "$STUB_DIR/pr97.md" <<'BODY'
## [![Quality Gate Passed](https://sonarsource.github.io/sonarcloud-github-static-resources/v2/checks/QualityGateBadge/qg-passed-20px.png 'Quality Gate Passed')](https://sonarcloud.io/dashboard?id=netresearch_data-tools-skill&pullRequest=97) **Quality Gate passed**
Issues
![](https://sonarsource.github.io/sonarcloud-github-static-resources/v2/common/passed-16px.png '') [1 New issue](https://sonarcloud.io/project/issues?id=netresearch_data-tools-skill&pullRequest=97&issueStatuses=OPEN,CONFIRMED&sinceLeakPeriod=true)
![](https://sonarsource.github.io/sonarcloud-github-static-resources/v2/common/accepted-16px.png '') [0 Accepted issues](https://sonarcloud.io/project/issues?id=netresearch_data-tools-skill&pullRequest=97&issueStatuses=ACCEPTED)

Measures
![](https://sonarsource.github.io/sonarcloud-github-static-resources/v2/common/passed-16px.png '') [0 Security Hotspots](https://sonarcloud.io/project/security_hotspots?id=netresearch_data-tools-skill&pullRequest=97&issueStatuses=OPEN,CONFIRMED&sinceLeakPeriod=true)
![](https://sonarsource.github.io/sonarcloud-github-static-resources/v2/common/passed-16px.png '') [0.0% Coverage on New Code](https://sonarcloud.io/component_measures?id=netresearch_data-tools-skill&pullRequest=97&metric=new_coverage&view=list)
![](https://sonarsource.github.io/sonarcloud-github-static-resources/v2/common/passed-16px.png '') [0.0% Duplication on New Code](https://sonarcloud.io/component_measures?id=netresearch_data-tools-skill&pullRequest=97&metric=new_duplicated_lines_density&view=list)

<!-- sqra-placement-anchor -->
[See analysis details on SonarQube Cloud](https://sonarcloud.io/dashboard?id=netresearch_data-tools-skill&pullRequest=97)

BODY

# case <name> <comments-json> <line: shown|absent> <sonar_new_issues>
# comments-json is a list of [login, typename, createdAt, body]; a body of
# "@pr97" stands for the verbatim comment above.
case_() {
  local name="$1" comments="$2" line="$3" want="$4"
  python3 - "$STUB_DIR/graphql.json" "$STUB_DIR/pr97.md" "$comments" <<'PY'
import sys, json
path, pr97, comments = sys.argv[1:4]
head = "deadbeefcafe"
body97 = open(pr97).read()
nodes = [{"author": None if login == "@ghost" else {"login": login, "__typename": typename},
          "body": body97 if body == "@pr97" else body,
          "url": "u", "createdAt": created, "lastEditedAt": None}
         for login, typename, created, body in json.loads(comments)]
json.dump({"data": {"viewer": {"login": "someone"}, "repository": {
    "nameWithOwner": "o/r",
    "mergeCommitAllowed": True, "rebaseMergeAllowed": False, "squashMergeAllowed": False,
    "autoMergeAllowed": True,
    "pullRequest": {
        "number": 7, "title": "t", "state": "OPEN", "isDraft": False,
        "createdAt": "2026-09-01T10:00:00Z", "lastEditedAt": "2026-09-04T10:00:00Z",
        "mergeQueue": None, "mergeQueueEntry": None,
        "mergeable": "MERGEABLE", "mergeStateStatus": "CLEAN", "reviewDecision": "APPROVED",
        "author": {"login": "someone", "__typename": "User"},
        "baseRefName": "main", "headRefName": "f", "headRefOid": head,
        "isCrossRepository": False,
        "comments": {"nodes": nodes},
        "reviews": {"nodes": [{"author": {"login": "reviewer"}, "state": "APPROVED",
                               "commit": {"oid": head}, "body": ""}]},
        "reviewRequests": {"nodes": []},
        "reviewThreads": {"nodes": []},
        "commits": {"nodes": [{"commit": {"oid": head, "committedDate": "2026-09-03T10:00:00Z",
            "statusCheckRollup": {
            "state": "SUCCESS", "contexts": {"pageInfo": {"hasNextPage": False}, "nodes": [
                {"__typename": "CheckRun", "name": "CI", "conclusion": "SUCCESS",
                 "status": "COMPLETED", "detailsUrl": "u",
                 "startedAt": "2026-01-01T00:00:00Z"}]}}}}]},
        "allCommits": {"nodes": [{"commit": {"oid": head, "signature": {"isValid": True}}}]},
    }}}}, open(path, "w"))
PY
  local text json got_line got_count got_next
  text="$(PATH="$STUB_DIR:$PATH" bash "$SCRIPT" -R o/r 7)"
  json="$(PATH="$STUB_DIR:$PATH" bash "$SCRIPT" -R o/r 7 --json)"
  if grep -q '^  sonar       : [0-9]* new issue(s) in the latest Quality Gate comment' <<<"$text"; then
    got_line=shown
  else
    got_line=absent
  fi
  got_count="$(jq -r '.sonar_new_issues' <<<"$json")"
  got_next="$(jq -r '.next.action' <<<"$json")"
  if [[ "$got_line" == "$line" && "$got_count" == "$want" && "$got_next" == "merge" ]]; then
    echo "  ok   $name"
  else
    echo "  FAIL $name: line=$got_line (want $line), sonar_new_issues=$got_count (want $want), next=$got_next (want merge)"
    fail=1
  fi
}

echo "pr-status.sh: new issues in a passed SonarCloud Quality Gate"

case_ "data-tools-skill#97 verbatim: passed gate with 1 new issue" \
      '[["sonarqubecloud", "Bot", "2026-09-03T11:00:00Z", "@pr97"]]' shown 1
case_ "no SonarCloud comment: line absent, null" \
      '[]' absent null
case_ "0 New issues: line absent" \
      '[["sonarqubecloud", "Bot", "2026-09-03T11:00:00Z", "**Quality Gate passed** [0 New issues](x)"]]' absent 0
# The newest comment wins, whatever order the API returns them in.
case_ "two comments: the newer count is reported" \
      '[["sonarqubecloud", "Bot", "2026-09-03T12:00:00Z", "**Quality Gate passed** [3 New issues](x)"],
        ["sonarqubecloud", "Bot", "2026-09-03T11:00:00Z", "**Quality Gate passed** [0 New issues](x)"]]' shown 3
case_ "older SonarCloud login sonarcloud is read too" \
      '[["sonarcloud", "Bot", "2026-09-03T11:00:00Z", "**Quality Gate failed** [2 New issues](x)"]]' shown 2
# A person whose login merely starts with sonarcloud does not speak for it.
# The author answers afterwards, so the person's comment does not raise the
# unanswered-comment rung, which would change NEXT for a reason unrelated here.
case_ "a User account named like the bot is ignored" \
      '[["sonarcloud-fan", "User", "2026-09-03T11:00:00Z", "[9 New issues](x)"],
        ["someone", "User", "2026-09-03T12:00:00Z", "noted"]]' absent null
# GitHub returns author null for a comment whose account was deleted. Every
# login test in the evaluator used to raise on it, and the report was empty.
# The author answers afterwards for the same reason as above.
case_ "a comment with a deleted author does not break the report" \
      '[["@ghost", "", "2026-09-03T10:30:00Z", "old remark"],
        ["sonarqubecloud", "Bot", "2026-09-03T11:00:00Z", "@pr97"],
        ["someone", "User", "2026-09-03T12:00:00Z", "noted"]]' shown 1

exit "$fail"
