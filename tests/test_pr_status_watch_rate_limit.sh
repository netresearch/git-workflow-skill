#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: Netresearch DTT GmbH
# Regression test: --watch must wait for the GraphQL rate-limit reset when the
# gate read failed on a rate limit, instead of retrying every interval.
#
# Observed 2026-09-29: three UNREADABLE retries 20 s apart, each failing with
# graphql_rate_limit while `gh api rate_limit` still showed budget. Every retry
# kept the limit engaged, and the watch had to be stopped by hand.
#
# Runs pr-status.sh against a stubbed `gh`, so it needs no network and no repo.

set -euo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/skills/git-workflow/scripts/pr-status.sh"
STUB_DIR="$(mktemp -d)"
trap 'rm -rf "$STUB_DIR"' EXIT

export XDG_CACHE_HOME="$STUB_DIR/cache"
export CALLS="$STUB_DIR/calls.log"

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

# Stub `gh` in the shape the real client has: for a GraphQL error the body
# (with "type":"RATE_LIMIT") goes to stdout and only `gh: <message>` to stderr
# (cli/cli pkg/cmd/api/api.go, processResponse). collect() re-emits stderr, so
# the message is what the watcher can see. `rate_limit` answers $RESET.
# Every call is logged with its epoch second.
cat > "$STUB_DIR/gh" <<'STUB'
#!/usr/bin/env bash
echo "$(date +%s) $*" >> "$CALLS"
case "$*" in
    *rate_limit*) echo "$RESET" ;;
    *graphql*)
        echo '{"data":null,"errors":[{"type":"RATE_LIMIT","code":"graphql_rate_limit","message":"API rate limit already exceeded for user ID 1."}]}'
        echo 'gh: API rate limit already exceeded for user ID 1.' >&2
        exit 1 ;;
    *) echo 'gh: unexpected call' >&2; exit 1 ;;
esac
STUB
chmod +x "$STUB_DIR/gh"

# Second stub: a failure that is not a rate limit.
mkdir -p "$STUB_DIR/auth"
cat > "$STUB_DIR/auth/gh" <<'STUB'
#!/usr/bin/env bash
echo "$(date +%s) $*" >> "$CALLS"
echo 'gh: Bad credentials (HTTP 401)' >&2
exit 1
STUB
chmod +x "$STUB_DIR/gh"

echo "case: rate-limited read — the watch sleeps to the reset, not to the interval"
RESET=$(( $(date +%s) + 4 )); export RESET
rc=0
out=$(PATH="$STUB_DIR:$PATH" bash "$SCRIPT" -R o/r 1 --watch --interval 1 --max-wait 6 2>/dev/null) || rc=$?
reset_iso=$(jq -rn --argjson t "$RESET" '$t | todate')

first_line=$(printf '%s\n' "$out" | grep -m1 'UNREADABLE' || true)
check_contains "names the rate limit"   "GitHub rate limit on o/r#1" "$first_line"
check_contains "names the reset time"   "$reset_iso" "$first_line"
check_contains "keeps the filter prefix" "pr-status: UNREADABLE" "$first_line"

gql_times=$(grep ' api graphql' "$CALLS" | cut -d' ' -f1)
before=0; after=0
for t in $gql_times; do
    if [ "$t" -lt "$RESET" ]; then before=$((before + 1)); else after=$((after + 1)); fi
done
# One read fails, then nothing until the reset. With the old interval retry
# there are four or five reads before it.
check "one gate read before the reset"  "1" "$before"
check "read again after the reset"      "true" "$([ "$after" -ge 1 ] && echo true || echo false)"
check "asked rate_limit for the reset"  "true" "$(grep -q ' api rate_limit' "$CALLS" && echo true || echo false)"
check "does not exit 0"                 "false" "$([ "$rc" = "0" ] && echo true || echo false)"

echo "case: rate_limit unreadable — bounded wait, capped at --max-wait"
: > "$CALLS"
RESET="null"; export RESET
start=$(date +%s); rc=0
out=$(PATH="$STUB_DIR:$PATH" bash "$SCRIPT" -R o/r 1 --watch --interval 1 --max-wait 3 2>/dev/null) || rc=$?
took=$(( $(date +%s) - start ))
check_contains "says the reset is unreadable" "GraphQL reset unreadable" "$out"
check_contains "times out"              "TIMEOUT after 3s" "$out"
# The 60 s fallback must not outlast --max-wait 3.
check "stays within --max-wait"         "true" "$([ "$took" -le 6 ] && echo true || echo false)"

echo "case: any other unreadable cause keeps the interval retry"
: > "$CALLS"
rc=0
out=$(PATH="$STUB_DIR/auth:$PATH" bash "$SCRIPT" -R o/r 1 --watch --interval 1 --max-wait 2 2>/dev/null) || rc=$?
check_contains "interval retry line"    "Retrying in 1s." "$out"
check "no rate_limit lookup"            "false" "$(grep -q ' api rate_limit' "$CALLS" && echo true || echo false)"
check "no rate-limit wait line"         "false" "$(case "$out" in *"GitHub rate limit"*) echo true ;; *) echo false ;; esac)"

exit "$fail"
