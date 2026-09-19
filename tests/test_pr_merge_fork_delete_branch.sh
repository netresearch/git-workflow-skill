#!/usr/bin/env bash
# A fork pull request keeps its head branch: `--delete-branch` tidies OUR
# branch, and on a cross-repository PR that branch belongs to the contributor.
# `gh` deletes it without complaint when the token has push rights through
# maintainerCanModify, so the flag has to be decided by the head repository,
# not only by the merge queue.
#
# Both directions are asserted: the flag must still be passed on a same-repo
# PR, or "never delete" would satisfy the suite just as well.
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

# status fixture. Args: <cross_repository> <queue_active>
make_status_stub() {
    cat > "$STUB_DIR/pr-status.sh" <<STUB
#!/usr/bin/env bash
cat <<JSON
{
  "repo": "o/r", "number": 106, "queue_active": $2,
  "merge_methods": ["merge"], "cross_repository": $1,
  "head": "feature/some-branch",
  "headOid": "deadbeefcafe0000", "author": "a-contributor",
  "author_is_bot": false, "self_review_on_head": true,
  "next": {"action": "merge", "why": "clean", "method": "--merge"}
}
JSON
STUB
    chmod +x "$STUB_DIR/pr-status.sh"
}

# A same-repo pull request now asks `gh pr list` whether another pull request is
# based on this branch (tests/test_pr_merge_stacked_pr_delete_branch.sh covers
# that check). Stub it as "nothing is stacked" so this test stays about the
# fork and queue cases, and needs no network.
cat > "$STUB_DIR/gh" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$STUB_DIR/gh"

run() { PATH="$STUB_DIR:$PATH" "$SCRIPT" -R o/r 106 --dry-run 2>"$STUB_DIR/err"; }

echo "case 1: fork PR — the head branch is not ours, so no --delete-branch"
make_status_stub true false
out=$(run)
says     "merges"            "gh pr merge 106 --repo o/r --merge" "$out"
says_not "keeps the branch"  "--delete-branch"                    "$out"

echo "case 2: same-repo PR — the flag is still passed"
make_status_stub false false
out=$(run)
says "deletes our own branch" "--delete-branch" "$out"

echo "case 3: merge queue still wins over both"
make_status_stub false true
out=$(run)
says_not "queue deletes it itself" "--delete-branch" "$out"

if [ "$fail" -eq 0 ]; then
    echo "all pass"
else
    echo "FAILURES"
    exit 1
fi
