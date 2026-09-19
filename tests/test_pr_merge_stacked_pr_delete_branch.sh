#!/usr/bin/env bash
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
  "head": "feature/base-of-another",
  "headOid": "deadbeefcafe0000", "author": "a-maintainer",
  "author_is_bot": false, "self_review_on_head": true,
  "next": {"action": "merge", "why": "clean", "method": "--merge"}
}
JSON
STUB
    chmod +x "$STUB_DIR/pr-status.sh"
}

# gh stub. Args: <pr-list-stdout> <pr-list-exit> [stderr]
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

if [ "$fail" -eq 0 ]; then
    echo "all pass"
else
    echo "FAILURES"
    exit 1
fi
