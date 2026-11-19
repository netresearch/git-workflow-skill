#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: Netresearch DTT GmbH
# pr-status.sh reads a GitLab merge request (#331): -R host/group/project <iid>,
# evaluated by pr-status-gitlab.jq.
#
# The gate is not read from detailed_merge_status alone, because it names only
# the gates the project enforces: a red pipeline, an open thread and a
# conflict are each read on their own and must win over "mergeable". An
# unmapped status must land on an actionable rung, never on merge or wait.
# pr-merge.sh must refuse a GitLab project before it calls anything.
#
# Runs against a stubbed glab that answers from fixture files, and a gh stub
# that records any call, because the GitLab path must not need gh.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS="$ROOT/skills/git-workflow/scripts"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
STUB="$WORK/bin"; FX="$WORK/fx"
mkdir -p "$STUB" "$FX"

fail=0
check() { if [ "$2" = "$3" ]; then echo "  ok   $1"; else echo "  FAIL $1: expected '$2', got '$3'"; fail=1; fi; }
says() { case "$3" in *"$2"*) echo "  ok   $1" ;; *) echo "  FAIL $1: output does not contain '$2'"; fail=1 ;; esac; }

# glab stub: answers by API path from $FX, logs every call. --paginate on a
# list prints the page files list.1, list.2 … one array each, as glab does.
cat > "$STUB/glab" <<STUBEOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$WORK/glab.log"
printf 'token=%s\n' "\${GITLAB_TOKEN:-}" >> "$WORK/glab.env"
paginate=0; path=""
for a in "\$@"; do
  case "\$a" in
    --paginate) paginate=1 ;;
    api|--hostname|gitlab.example.com) ;;
    *) path="\$a" ;;
  esac
done
path="\${path%%\?*}"
case "\$path" in
  projects/group%2Fsub%2Fproject/merge_requests/7) cat "$FX/mr.json" ;;
  projects/group%2Fsub%2Fproject/merge_requests/7/approvals) cat "$FX/approvals.json" ;;
  projects/group%2Fsub%2Fproject/merge_requests/7/discussions) cat "$FX"/discussions.*.json ;;
  projects/group%2Fsub%2Fproject) cat "$FX/project.json" ;;
  projects/group%2Fsub%2Fproject/pipelines/*/jobs) cat "$FX/jobs.json" ;;
  projects/group%2Fsub%2Fproject/repository/commits/*) cat "$FX/commit.json" ;;
  user) echo '{"username":"viewer"}' ;;
  *) echo "glab stub: unknown path \$path" >&2; exit 1 ;;
esac
STUBEOF
printf '#!/usr/bin/env bash\necho "gh \$*" >> "%s/gh.log"; exit 1\n' "$WORK" > "$STUB/gh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB/sleep"
chmod +x "$STUB/glab" "$STUB/gh" "$STUB/sleep"

HEAD=aaaaaaaabbbbbbbbccccccccddddddddeeeeeeee
# fixture <detailed_merge_status> <pipeline status|none> [pipeline sha] — resets the rest
fixture() {
  local pl="null"
  [ "$2" = "none" ] || pl="{\"id\": 900, \"status\": \"$2\", \"sha\": \"${3:-$HEAD}\"}"
  cat > "$FX/mr.json" <<JSON
{"iid": 7, "title": "Add a feature", "state": "opened", "draft": false,
 "merge_status": "can_be_merged", "detailed_merge_status": "$1",
 "has_conflicts": false, "blocking_discussions_resolved": true,
 "sha": "$HEAD", "source_branch": "feature", "target_branch": "main",
 "source_project_id": 1, "target_project_id": 1,
 "author": {"username": "author", "bot": false},
 "web_url": "https://gitlab.example.com/group/sub/project/-/merge_requests/7",
 "head_pipeline": $pl}
JSON
  echo '{"approved_by": [{"user": {"username": "reviewer"}}]}' > "$FX/approvals.json"
  rm -f "$FX"/discussions.*.json
  echo '[{"id": "d1", "individual_note": true, "notes": [{"resolvable": false}]}]' > "$FX/discussions.1.json"
  echo '{"merge_method": "merge", "squash_option": "default_on"}' > "$FX/project.json"
  echo '[{"name": "test", "status": "success", "allow_failure": false}]' > "$FX/jobs.json"
  : > "$WORK/glab.log"; : > "$WORK/gh.log"
}
mr_set() { jq "$1" "$FX/mr.json" > "$FX/mr.tmp" && mv "$FX/mr.tmp" "$FX/mr.json"; }

run() { PATH="$STUB:$PATH" "$SCRIPTS/pr-status.sh" -R gitlab.example.com/group/sub/project 7 "$@" 2>"$WORK/err"; }
next() { run --json | jq -r '.next.action'; }

echo "case 1: everything clear — merge, with a non-squashing merge command"
fixture mergeable success
out=$(run --json)
check "action"          "merge"  "$(jq -r .next.action <<<"$out")"
says  "merge command"   "-X PUT projects/group%2Fsub%2Fproject/merge_requests/7/merge -f squash=false -f sha=$HEAD" "$(jq -r .next.cmd <<<"$out")"
check "state mapped"    "OPEN"   "$(jq -r .state <<<"$out")"
check "repo kept whole" "gitlab.example.com/group/sub/project" "$(jq -r .repo <<<"$out")"
check "gh never called" "0"      "$(wc -l < "$WORK/gh.log")"
says  "nested groups are encoded" "projects/group%2Fsub%2Fproject/merge_requests/7" "$(cat "$WORK/glab.log")"
txt=$(run)
says  "prose rendering" "NEXT: merge" "$txt"
says  "prose names the MR" "MR !7  Add a feature" "$txt"

echo "case 2: GitLab says mergeable but the head pipeline failed — fix-ci"
fixture mergeable failed
echo '[{"name": "lint", "status": "failed", "allow_failure": false}, {"name": "flaky", "status": "failed", "allow_failure": true}]' > "$FX/jobs.json"
out=$(run --json)
check "action"          "fix-ci" "$(jq -r .next.action <<<"$out")"
says  "names the job"   "lint"   "$(jq -r .next.why <<<"$out")"
check "allowed failure is not failing" '["lint"]' "$(jq -c .checks.failing <<<"$out")"

echo "case 3: an unresolved thread on page two — resolve-threads"
fixture mergeable success
echo '[{"id": "d2", "individual_note": false, "notes": [{"resolvable": true, "resolved": false}]}]' > "$FX/discussions.2.json"
check "action" "resolve-threads" "$(next)"
check "count"  "1" "$(run --json | jq -r .unresolved_threads)"

echo "case 4: the head pipeline is for an older sha — wait, not merge"
fixture mergeable success 1111111111111111111111111111111111111111
check "action" "wait" "$(next)"

echo "case 4b: a merged results pipeline on a merge commit of the head — merge"
fixture mergeable success 2222222222222222222222222222222222222222
mr_set '.head_pipeline.ref = "refs/merge-requests/7/merge"'
echo "{\"parent_ids\": [\"3333333333333333333333333333333333333333\", \"$HEAD\"]}" > "$FX/commit.json"
check "action" "merge" "$(next)"
echo '{"parent_ids": ["3333333333333333333333333333333333333333", "4444444444444444444444444444444444444444"]}' > "$FX/commit.json"
check "a merge commit of another head still waits" "wait" "$(next)"
echo "{\"parent_ids\": [\"3333333333333333333333333333333333333333\", \"$HEAD\"]}" > "$FX/commit.json"
mr_set '.head_pipeline.ref = "refs/merge-requests/7/train" | .head_pipeline.status = "failed"'
echo '[{"name": "lint", "status": "failed", "allow_failure": false}]' > "$FX/jobs.json"
check "a red merge train pipeline of the head answers fix-ci" "fix-ci" "$(next)"

echo "case 5: conflicts reported while the status still says mergeable"
fixture mergeable success; mr_set '.has_conflicts = true'
check "action" "resolve-conflicts" "$(next)"

echo "case 6: draft — ready"
fixture draft_status none; mr_set '.draft = true'
check "action" "ready" "$(next)"
check "cmd names the host as a URL" "glab mr update 7 --ready --repo https://gitlab.example.com/group/sub/project" "$(run --json | jq -r .next.cmd)"

echo "case 7: an unmapped status is actionable and names itself"
fixture jira_association_missing success
out=$(run --json)
check "action" "blocked" "$(jq -r .next.action <<<"$out")"
says  "raw value in why" "jira_association_missing" "$(jq -r .next.why <<<"$out")"

echo "case 8: a pipeline still running — await-checks"
fixture ci_still_running running
echo '[{"name": "test", "status": "running", "allow_failure": false}]' > "$FX/jobs.json"
check "action" "await-checks" "$(next)"

echo "case 9: squash_option always — blocked, squash is not used"
fixture mergeable success
echo '{"merge_method": "merge", "squash_option": "always"}' > "$FX/project.json"
check "action" "blocked" "$(next)"

echo "case 10: merged — none, and state MERGED for pr-sweep"
fixture not_open none; mr_set '.state = "merged"'
out=$(run --json)
check "action" "none"   "$(jq -r .next.action <<<"$out")"
check "state"  "MERGED" "$(jq -r .state <<<"$out")"

echo "case 11: not approved — request-review; no approval at merge is said"
fixture not_approved success
check "action" "request-review" "$(next)"
fixture mergeable success; echo '{"approved_by": []}' > "$FX/approvals.json"
says  "merge note names the missing approval" "Nobody has approved" "$(run --json | jq -r .next.note)"

echo "case 12: --watch returns on the failed job"
fixture mergeable failed
echo '[{"name": "lint", "status": "failed", "allow_failure": false}]' > "$FX/jobs.json"
out=$(PATH="$STUB:$PATH" timeout 30 "$SCRIPTS/pr-status.sh" -R gitlab.example.com/group/sub/project 7 --watch 2>/dev/null); rc=$?
check "exit"   "0" "$rc"
says  "returns on the check" "ACTIONABLE: check failed -> lint" "$out"

echo "case 13: a failed read is an error, not a verdict"
fixture mergeable success; rm -f "$FX"/discussions.*.json
run --json >/dev/null; rc=$?
check "exit 2" "2" "$rc"
says  "names the read" "discussions" "$(cat "$WORK/err")"

echo "case 14: pr-merge.sh refuses a GitLab project before calling anything"
fixture mergeable success
out=$(PATH="$STUB:$PATH" "$SCRIPTS/pr-merge.sh" -R gitlab.example.com/group/sub/project 7 2>&1); rc=$?
check "exit 2" "2" "$rc"
says  "says why" "GitHub pull requests only" "$out"
check "no glab call" "0" "$(wc -l < "$WORK/glab.log")"
check "no gh call"   "0" "$(wc -l < "$WORK/gh.log")"

echo "case 14b: an environment token reaches only the GITLAB_HOST host"
fixture mergeable success; : > "$WORK/glab.env"
GITLAB_TOKEN=secret GITLAB_HOST=other.example.com run --json >/dev/null
check "not sent to another host" "0" "$(grep -c 'token=secret' "$WORK/glab.env")"
: > "$WORK/glab.env"
GITLAB_TOKEN=secret GITLAB_HOST=gitlab.example.com run --json >/dev/null
check "sent to the GITLAB_HOST host" "1" "$([ "$(grep -c 'token=secret' "$WORK/glab.env")" -gt 0 ] && echo 1 || echo 0)"

: > "$WORK/glab.env"
GITLAB_TOKEN=secret GITLAB_HOST='' GITLAB_URL=https://gitlab.example.com/ run --json >/dev/null
check "GITLAB_URL in URL form names the same host" "1" "$([ "$(grep -c 'token=secret' "$WORK/glab.env")" -gt 0 ] && echo 1 || echo 0)"

echo "case 15: a GitHub owner/repo is still GitHub"
: > "$WORK/gh.log"; : > "$WORK/glab.log"
PATH="$STUB:$PATH" "$SCRIPTS/pr-status.sh" -R owner/repo 1 --json >/dev/null 2>&1
check "glab not called" "0" "$(wc -l < "$WORK/glab.log")"
check "gh called"       "1" "$([ -s "$WORK/gh.log" ] && echo 1 || echo 0)"

if [ "$fail" -eq 0 ]; then echo "all pass"; else echo "FAILURES"; exit 1; fi
