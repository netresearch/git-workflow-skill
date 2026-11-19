#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: Netresearch DTT GmbH
# A branch that another open pull request uses as its BASE must survive the
# merge. Deleting it closes that pull request, and a closed pull request's base
# cannot be retargeted — recovery means pushing the branch back, reopening,
# retargeting and only then deleting.
#
# Four directions are asserted, because "never delete" would satisfy a
# one-sided suite just as well: the flag is withheld when a dependent pull
# request exists, still passed when none does, withheld again when the query
# itself fails, and withheld when no head branch was reported — an answer to a
# question that was never put reads exactly like "nothing is stacked". The last
# case goes further than the flag: a query that fails after printing must not
# have its partial output reported as the list of dependent pull requests.
#
# Cases 6 to 11 cover a repository with delete_branch_on_merge on, where
# GitHub deletes the branch even without --delete-branch (#460): the merge is
# refused with the retarget commands, or --retarget-stacked retargets first.
#
# Runs against a stubbed pr-status.sh and a stubbed `gh`, so it needs no
# network and no repo.

set -uo pipefail

REAL="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/skills/git-workflow/scripts/pr-merge.sh"
STUB_DIR="$(mktemp -d)"
trap 'rm -rf "$STUB_DIR"' EXIT
SCRIPT="$STUB_DIR/pr-merge.sh"
cp "$REAL" "$SCRIPT"

fail=0
says() { # says <name> <pattern> <haystack>
    case "$3" in
        *"$2"*) echo "  ok   $1" ;;
        *)      echo "  FAIL $1: output does not contain '$2'"; fail=1 ;;
    esac
}
says_not() { # says_not <name> <pattern> <haystack>
    case "$3" in
        *"$2"*) echo "  FAIL $1: output wrongly contains '$2'"; fail=1 ;;
        *)      echo "  ok   $1" ;;
    esac
}

make_status_stub() {
    cat > "$STUB_DIR/pr-status.sh" <<'STUB'
#!/usr/bin/env bash
cat <<'JSON'
{
  "repo": "o/r", "number": 107, "queue_active": false,
  "merge_methods": ["merge"], "cross_repository": false,
  "head": "feature/base-of-another", "base": "main",
  "headOid": "deadbeefcafe0000", "author": "a-maintainer",
  "author_is_bot": false, "self_review_on_head": true,
  "next": {"action": "merge", "why": "clean", "method": "--merge"}
}
JSON
STUB
    chmod +x "$STUB_DIR/pr-status.sh"
}

# gh stub. Args: <pr-list-stdout> <pr-list-exit> [stderr] [delete_branch_on_merge] [its exit]
# It records its own argv, so a query against the wrong branch or the wrong
# repository is a test failure rather than an invisible regression.
make_gh_stub() {
    : > "$STUB_DIR/gh-args"
    cat > "$STUB_DIR/gh" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$STUB_DIR/gh-args"
if [ "\$1" = "pr" ] && [ "\$2" = "list" ]; then
  printf '%s' '$1'
  printf '%s' '${3:-}' >&2
  exit $2
fi
if [ "\$1" = "api" ] && [ "\$2" = "graphql" ] && printf '%s' "\$*" | grep -q deleteBranchOnMerge; then
  printf '%s\n' '${4:-false}'
  exit ${5:-0}
fi
if [ "\$1" = "api" ] && [ "\$2" = "graphql" ]; then
  printf '%s' '{"data":{"repository":{"pullRequest":{"state":"MERGED","isInMergeQueue":false,"autoMergeRequest":null}}}}'
  exit 0
fi
if [ "\$1" = "api" ] && [ "\$2" = "repos/o/r/rules/branches/feature%2Fbase-of-another" ]; then
  printf '%s\n' "\${STUB_DELRULE:-0}"
  exit 0
fi
if [ "\$1" = "api" ] && [ "\$2" = "repos/o/r/branches/feature%2Fbase-of-another/protection" ]; then
  [ -n "\${STUB_ALLOWDEL:-}" ] || { echo "gh: Must have admin rights to Repository. (HTTP 403)" >&2; exit 1; }
  [ "\$STUB_ALLOWDEL" != "none" ] || { echo "gh: Branch not protected (HTTP 404)" >&2; exit 1; }
  printf '%s\n' "\$STUB_ALLOWDEL"
  exit 0
fi
if [ "\$1" = "api" ] && [ "\$2" = "repos/o/r/branches/feature%2Fbase-of-another" ]; then
  printf '%s\n' "\${STUB_PROTECTED:-false}"
  exit 0
fi
if [ "\$1" = "pr" ] && [ "\$2" = "view" ]; then
  printf 'main\n'
  exit 0
fi
exit 0
STUB
    chmod +x "$STUB_DIR/gh"
}

run() { PATH="$STUB_DIR:$PATH" "$SCRIPT" -R o/r 107 --dry-run 2>"$STUB_DIR/err"; }

make_status_stub

echo "case 1: another open PR is based on this branch — keep it"
make_gh_stub '#108 #109' 0
out=$(run); err=$(cat "$STUB_DIR/err"); args=$(cat "$STUB_DIR/gh-args")
says     "merges"                    "gh pr merge 107 --repo o/r --merge" "$out"
says_not "keeps the branch"          "--delete-branch"                    "$out"
says     "names the dependent PRs"   "#108 #109"                          "$err"
says     "names the branch"          "feature/base-of-another"            "$err"
says     "asks about the HEAD branch" "--base feature/base-of-another"    "$args"
says     "asks the right repository" "--repo o/r"                         "$args"
says     "asks for open PRs only"    "--state open"                       "$args"
says     "asks past gh's default of 30" "--limit 1000"                    "$args"

echo "case 2: nothing is based on it — the flag is still passed"
make_gh_stub '' 0
out=$(run); err=$(cat "$STUB_DIR/err")
says     "deletes our own branch"    "--delete-branch"                    "$out"
says_not "says nothing about stacks" "Retarget them"                      "$err"

echo "case 3: the query failed — an empty answer must not read as 'none'"
make_gh_stub '' 1 'gh: HTTP 403'
out=$(run); err=$(cat "$STUB_DIR/err")
says_not "keeps the branch"          "--delete-branch"                    "$out"
says     "says it could not check"   "could not check for dependent"      "$err"
says     "relays why"                "HTTP 403"                           "$err"

echo "case 4: no head branch reported — the same doubt, the same answer"
make_gh_stub '' 0
cat > "$STUB_DIR/pr-status.sh" <<'STUB'
#!/usr/bin/env bash
cat <<'JSON'
{
  "repo": "o/r", "number": 107, "queue_active": false,
  "merge_methods": ["merge"], "cross_repository": false,
  "headOid": "deadbeefcafe0000", "author": "a-maintainer",
  "author_is_bot": false, "self_review_on_head": true,
  "next": {"action": "merge", "why": "clean", "method": "--merge"}
}
JSON
STUB
chmod +x "$STUB_DIR/pr-status.sh"
out=$(run); err=$(cat "$STUB_DIR/err"); args=$(cat "$STUB_DIR/gh-args")
says_not "keeps the branch"          "--delete-branch"                    "$out"
says     "says it could not check"   "no head branch"                     "$err"
says_not "does not query blindly"    "pr list"                            "$args"

echo "case 5: the query failed after printing — the output is not a PR list"
make_status_stub
make_gh_stub '#901 #902' 1 'gh: connection reset'
out=$(run); err=$(cat "$STUB_DIR/err")
says_not "keeps the branch"          "--delete-branch"                    "$out"
says     "says it could not check"   "could not check for dependent"      "$err"
says_not "invents no dependents"     "#901 #902"                          "$err"

# The repository can delete the merged head branch itself. With
# delete_branch_on_merge on, withholding --delete-branch keeps nothing, so a
# merge with open children is refused until they are retargeted.
echo "case 6: delete_branch_on_merge is on — refuse, name the retarget"
make_status_stub
make_gh_stub '#108 #109' 0 '' true
out=$(run); rc=$?; err=$(cat "$STUB_DIR/err"); args=$(cat "$STUB_DIR/gh-args")
says     "exits 2 (needs a human)"   "rc=2"                               "rc=$rc"
says_not "does not merge"            "gh pr merge"                        "$out"
says     "names the dependent PRs"   "#108 #109"                          "$err"
says     "names the setting"         "delete_branch_on_merge"             "$err"
says     "gives the retarget command" "gh pr edit 108 --repo o/r --base main" "$err"
says     "for every child"           "gh pr edit 109 --repo o/r --base main" "$err"
says     "names the flag"            "--retarget-stacked"                 "$err"
says     "reads the setting through GraphQL" "deleteBranchOnMerge"      "$args"

echo "case 6b: a base branch name with shell syntax is printed quoted"
sed -i 's/"base": "main"/"base": "rel;touch x"/' "$STUB_DIR/pr-status.sh"
make_gh_stub '#108' 0 '' true
out=$(run); err=$(cat "$STUB_DIR/err")
says     "quotes the base"           'rel\;touch\ x'                      "$err"
make_status_stub

echo "case 7: delete_branch_on_merge is off — merge and keep the branch, as before"
make_gh_stub '#108' 0 '' false
out=$(run); rc=$?; err=$(cat "$STUB_DIR/err")
says     "exits 0"                   "rc=0"                               "rc=$rc"
says     "merges"                    "gh pr merge 107 --repo o/r --merge" "$out"
says_not "keeps the branch"          "--delete-branch"                    "$out"

echo "case 8: the setting cannot be read — no merge on a guess"
make_gh_stub '#108' 0 '' '' 1
out=$(run); rc=$?; err=$(cat "$STUB_DIR/err")
says     "exits 2"                   "rc=2"                               "rc=$rc"
says_not "does not merge"            "gh pr merge"                        "$out"
says     "says what it could not read" "delete_branch_on_merge"           "$err"

echo "case 8b: the setting reads as null — not 'off'"
make_gh_stub '#108' 0 '' null
out=$(run); rc=$?; err=$(cat "$STUB_DIR/err")
says     "exits 2"                   "rc=2"                               "rc=$rc"
says_not "does not merge"            "gh pr merge"                        "$out"
says     "names the value"           "'null'"                             "$err"

echo "case 9: dependents unknown and the setting is on — no merge"
make_gh_stub '' 1 'gh: HTTP 403' true
out=$(run); rc=$?; err=$(cat "$STUB_DIR/err")
says     "exits 2"                   "rc=2"                               "rc=$rc"
says_not "does not merge"            "gh pr merge"                        "$out"
says     "relays why"                "HTTP 403"                           "$err"

echo "case 10: --retarget-stacked --dry-run prints the retargets before the merge"
make_gh_stub '#108 #109' 0 '' true
out=$(PATH="$STUB_DIR:$PATH" "$SCRIPT" -R o/r 107 --retarget-stacked --dry-run 2>"$STUB_DIR/err"); rc=$?
args=$(cat "$STUB_DIR/gh-args")
says     "exits 0"                   "rc=0"                               "rc=$rc"
says     "prints the retarget"       "gh pr edit 108 --repo o/r --base main" "$out"
says     "prints the merge"          "gh pr merge 107 --repo o/r --merge" "$out"
says_not "edits nothing in a dry run" "pr edit"                           "$args"
err=$(cat "$STUB_DIR/err")
says     "says the retarget would happen" "would retarget"               "$err"
says_not "does not claim it happened" "now target"                        "$err"

echo "case 11: --retarget-stacked retargets each child, then merges"
make_gh_stub '#108 #109' 0 '' true
out=$(PATH="$STUB_DIR:$PATH" "$SCRIPT" -R o/r 107 --retarget-stacked 2>"$STUB_DIR/err"); rc=$?
args=$(cat "$STUB_DIR/gh-args")
says     "exits 0"                   "rc=0"                               "rc=$rc"
says     "retargets #108"            "pr edit 108 --repo o/r --base main" "$args"
says     "retargets #109"            "pr edit 109 --repo o/r --base main" "$args"
says     "reads the base back"       "pr view 108"                        "$args"
says     "merges after"              "pr merge 107 --repo o/r --merge"    "$args"
err=$(cat "$STUB_DIR/err")
says_not "does not ask to retarget what it retargeted" "Retarget them" "$err"
says     "says the repository deletes the branch" "deletes feature/base-of-another" "$err"
first_edit=$(grep -n 'pr edit' <<<"$args" | head -n1 | cut -d: -f1)
merge_line=$(grep -n 'pr merge' <<<"$args" | head -n1 | cut -d: -f1)
says     "retargets before merging"  "yes"                                "$([ "${first_edit:-99}" -lt "${merge_line:-0}" ] && echo yes)"

echo "case 12: a merge queue is checked the same way"
cat > "$STUB_DIR/pr-status.sh" <<'STUB'
#!/usr/bin/env bash
cat <<'JSON'
{
  "repo": "o/r", "number": 107, "queue_active": true,
  "merge_methods": ["merge"], "cross_repository": false,
  "head": "feature/base-of-another", "base": "main",
  "headOid": "deadbeefcafe0000", "author": "a-maintainer",
  "author_is_bot": false, "self_review_on_head": true,
  "next": {"action": "merge", "why": "clean", "method": "--merge"}
}
JSON
STUB
chmod +x "$STUB_DIR/pr-status.sh"
make_gh_stub '#108' 0 '' true
out=$(run); rc=$?; err=$(cat "$STUB_DIR/err")
says     "exits 2"                   "rc=2"                               "rc=$rc"
says_not "does not enqueue"          "gh pr merge"                        "$out"
says     "names the dependent PR"    "#108"                               "$err"
make_gh_stub '' 0 '' true
out=$(run); rc=$?
says     "an unstacked queued merge goes ahead" "gh pr merge 107 --repo o/r --merge" "$out"
says_not "and never passes --delete-branch to the queue" "--delete-branch" "$out"

run_flag() { PATH="$STUB_DIR:$PATH" "$SCRIPT" -R o/r 107 --retarget-stacked --dry-run 2>"$STUB_DIR/err"; }

echo "case 13: a deletion rule keeps the head — merge as before, retarget nothing"
make_status_stub
make_gh_stub '#108' 0 '' true
out=$(STUB_DELRULE=1 run_flag); rc=$?
says     "exits 0"                   "rc=0"                               "rc=$rc"
says     "merges"                    "gh pr merge 107 --repo o/r --merge" "$out"
says_not "retargets nothing"         "gh pr edit"                         "$out"
says     "reads the rules"           "rules/branches/feature%2Fbase-of-another" "$(cat "$STUB_DIR/gh-args")"

echo "case 13b: classic protection with allow_deletions off keeps the head"
make_gh_stub '#108' 0 '' true
out=$(STUB_PROTECTED=true STUB_ALLOWDEL=false run_flag); rc=$?
says     "exits 0"                   "rc=0"                               "rc=$rc"
says_not "retargets nothing"         "gh pr edit"                         "$out"

echo "case 13c: protected, deletion allowed — the head is deleted, so retarget"
make_gh_stub '#108' 0 '' true
out=$(STUB_PROTECTED=true STUB_ALLOWDEL=true run_flag); rc=$?
says     "exits 0"                   "rc=0"                               "rc=$rc"
says     "retargets"                 "gh pr edit 108 --repo o/r --base main" "$out"

echo "case 13d: protected, protection unreadable (no admin) — nothing on a guess"
make_gh_stub '#108' 0 '' true
out=$(STUB_PROTECTED=true run_flag); rc=$?; err=$(cat "$STUB_DIR/err")
says     "exits 2"                   "rc=2"                               "rc=$rc"
says_not "does not merge"            "gh pr merge"                        "$out"
says_not "does not retarget"         "gh pr edit"                         "$out"
says     "says why"                  "could not be read"                  "$err"

echo "case 13e: protected by a ruleset without a deletion rule (no classic protection) — retarget"
make_gh_stub '#108' 0 '' true
out=$(STUB_PROTECTED=true STUB_DELRULE=0 STUB_ALLOWDEL=none run_flag); rc=$?
says     "retargets"                 "gh pr edit 108 --repo o/r --base main" "$out"

if [ "$fail" -eq 0 ]; then
    echo "all pass"
else
    echo "FAILURES"
    exit 1
fi
