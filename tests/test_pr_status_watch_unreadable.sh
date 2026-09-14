#!/usr/bin/env bash
# Regression test: --watch must report a snapshot it could not read as its own
# state, not as "still waiting".
#
# `die` inside $( ) kills only the subshell, so a failed collect left $s empty,
# wrote its reason to stderr — which a watcher harness never turns into an
# event — and then printed a bare `waiting:` on stdout every interval. A quiet
# gate and a broken query were indistinguishable on the stream the operator
# actually reads.
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
check_absent() { # check_absent <name> <needle> <haystack>
    case "$3" in
        *"$2"*) echo "  FAIL $1: unexpected '$2' in output"; fail=1 ;;
        *) echo "  ok   $1" ;;
    esac
}

# Stub `gh`: every call fails the way a rate-limited or unauthorised one does.
# The message goes to stderr, exactly where the real client puts it.
cat > "$STUB_DIR/gh" <<'STUB'
#!/usr/bin/env bash
echo 'gh: API rate limit already exceeded for user ID 1' >&2
exit 1
STUB
chmod +x "$STUB_DIR/gh"

watch() { PATH="$STUB_DIR:$PATH" bash "$SCRIPT" -R o/r 1 --watch "$@"; }

echo "case: unreadable gate — stdout says so, and never claims to be waiting"
rc=0; out=$(watch --interval 1 --max-wait 2 2>/dev/null) || rc=$?
check_contains "names the state"        "UNREADABLE" "$out"
check_contains "names the PR"           "o/r#1" "$out"
check_absent   "no bare waiting: line"  "waiting:" "$out"

echo "case: the line survives the documented watcher filter"
# references/merge-gate-watcher.md drops the heartbeat and keeps only the lines
# worth acting on. A state that does not match it is a state nobody sees.
filtered=$(printf '%s\n' "$out" \
    | grep -vE '^waiting' \
    | grep -E '^(ACTIONABLE|TIMEOUT|SETTLED|NEXT)|^\s*(failing|checks)|pr-status:' || true)
check_contains "kept by the filter"     "UNREADABLE" "$filtered"

echo "case: the cause reaches stderr, not just the generic failure line"
# collect() swallows gh's chatter on success but must re-emit it on failure —
# the message points the operator at stderr, so stderr has to carry the reason.
err=$(watch --interval 1 --max-wait 2 2>&1 >/dev/null || true)
check_contains "gh diagnostic present"  "API rate limit already exceeded" "$err"

echo "case: it keeps retrying rather than returning a verdict"
# The watch must not exit 0 on an unreadable gate: exit 0 reads as "actionable
# state reached" to every caller, including pr-merge.sh.
check         "does not exit 0"         "false" "$([ "$rc" = "0" ] && echo true || echo false)"

exit "$fail"
