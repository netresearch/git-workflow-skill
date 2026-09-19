#!/usr/bin/env bash
# A branch that another open pull request uses as its BASE must survive the
# merge. Deleting it closes that pull request, and a closed pull request's base
# cannot be retargeted — recovery means pushing the branch back, reopening,
# retargeting and only then deleting.
#
# Three directions are asserted, because "never delete" would satisfy a
# one-sided suite just as well: the flag is withheld when a dependent pull
# request exists, still passed when none does, and withheld again when the
# query itself fails — an empty answer from a broken query reads exactly like
# "nothing is stacked".
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

# gh stub. Args: <pr-list-json> <pr-list-exit>
make_gh_stub() {
    cat > "$STUB_DIR/gh" <<STUB
#!/usr/bin/env bash
if [ "\$1" = "pr" ] && [ "\$2" = "list" ]; then
  printf '%s' '$1'
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
out=$(run); err=$(cat "$STUB_DIR/err")
says     "merges"                    "gh pr merge 107 --repo o/r --merge" "$out"
says_not "keeps the branch"          "--delete-branch"                    "$out"
says     "names the dependent PRs"   "#108 #109"                          "$err"
says     "names the branch"          "feature/base-of-another"            "$err"

echo "case 2: nothing is based on it — the flag is still passed"
make_gh_stub '' 0
out=$(run); err=$(cat "$STUB_DIR/err")
says     "deletes our own branch"    "--delete-branch"                    "$out"
says_not "says nothing about stacks" "Retarget them"                      "$err"

echo "case 3: the query failed — an empty answer must not read as 'none'"
make_gh_stub '' 1
out=$(run); err=$(cat "$STUB_DIR/err")
says_not "keeps the branch"          "--delete-branch"                    "$out"
says     "says the query failed"     "could not be determined"            "$err"

if [ "$fail" -eq 0 ]; then
    echo "all pass"
else
    echo "FAILURES"
    exit 1
fi
