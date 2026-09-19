#!/usr/bin/env bash
# Regression test: the single-shot read must not exit 0 on a gate it could not
# read.
#
# `snapshot()` guards its GraphQL read with `die`, but every call site is a
# command substitution, so that `exit 2` terminates the subshell only. `--watch`
# grew its own branch for this (test_pr_status_watch_unreadable.sh); the
# single-shot path kept `emit "$(snapshot)"` followed by `exit 0`, so a failed
# read printed one line on stderr, nothing on stdout, and returned success.
# Any caller keying on the exit status — a hook, a Makefile, a monitor — read a
# failed gate read as a passed gate.
#
# Reported as netresearch/git-workflow-skill#275, where it was observed against
# a valid PR under a GraphQL secondary rate limit.
#
# Runs pr-status.sh against a stubbed `gh` that fails, so it needs no network
# and no repo.

set -euo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/skills/git-workflow/scripts/pr-status.sh"
STUB_DIR="$(mktemp -d)"
trap 'rm -rf "$STUB_DIR"' EXIT

export XDG_CACHE_HOME="$STUB_DIR/cache"

fail=0
check() { # check <name> <expected> <actual>
    if [ "$2" = "$3" ]; then
        echo "  ok   $1"
    else
        echo "  FAIL $1: expected '$2', got '$3'"
        fail=1
    fi
}
check_contains() { # check_contains <name> <needle> <haystack>
    case "$3" in
        *"$2"*) echo "  ok   $1" ;;
        *) echo "  FAIL $1: no '$2' in output"; fail=1 ;;
    esac
}

cat > "$STUB_DIR/gh" <<'STUB'
#!/usr/bin/env bash
echo 'gh: API rate limit already exceeded for user ID 1' >&2
exit 1
STUB
chmod +x "$STUB_DIR/gh"

run() { PATH="$STUB_DIR:$PATH" bash "$SCRIPT" -R o/r 1 "$@"; }

echo "case: human output — a failed read is not a successful run"
rc=0; out=$(run 2>/dev/null) || rc=$?
check       "does not exit 0"        "false" "$([ "$rc" = "0" ] && echo true || echo false)"
check       "stdout is empty"        ""      "$out"

echo "case: the reason reaches stderr"
err=$(run 2>&1 >/dev/null || true)
check_contains "gh diagnostic present" "API rate limit already exceeded" "$err"
check_contains "names the PR"          "o/r#1" "$err"

echo "case: --json — a caller piping into jq gets a failure, not an empty success"
rc=0; out=$(run --json 2>/dev/null) || rc=$?
check       "does not exit 0"        "false" "$([ "$rc" = "0" ] && echo true || echo false)"
check       "stdout is empty"        ""      "$out"

echo "case: a readable gate still exits 0"
# The guard must not turn every run into a failure: with a stub that answers,
# the ordinary path is unchanged. Without this the whole file would pass
# against a pr-status.sh that simply always failed.
cat > "$STUB_DIR/gh" <<'STUB'
#!/usr/bin/env bash
for arg in "$@"; do
    case "$arg" in
        # rulesets / classic protection / anything REST: empty is fine
        repos/*) echo '[]'; exit 0 ;;
    esac
done
cat <<'JSON'
{"data":{"repository":{"pullRequest":{
  "number":1,"title":"t","state":"OPEN","isDraft":false,"mergeable":"MERGEABLE",
  "mergeStateStatus":"CLEAN","reviewDecision":"","baseRefName":"main",
  "headRefName":"f","isCrossRepository":false,
  "author":{"login":"someone","__typename":"User"},
  "reviewRequests":{"nodes":[]},"reviewThreads":{"nodes":[]},
  "comments":{"nodes":[]},"latestReviews":{"nodes":[]},"reviews":{"nodes":[]},
  "commits":{"nodes":[{"commit":{"oid":"deadbeefdeadbeefdeadbeefdeadbeefdeadbeef",
    "signature":null,"statusCheckRollup":{"state":"SUCCESS","contexts":{"nodes":[]}}}}]}
}}}}
JSON
STUB
chmod +x "$STUB_DIR/gh"
rc=0; out=$(run --json 2>/dev/null) || rc=$?
check "readable gate exits 0" "0" "$rc"
check_contains "and emits JSON" '"number"' "$out"

exit "$fail"
