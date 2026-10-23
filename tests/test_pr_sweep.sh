#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: Netresearch DTT GmbH
# Regression test: pr-sweep.sh stops on every action it does not handle.
#
# Hand-written sweep drivers dispatched on a few `NEXT:` values and sent the
# rest into a default "wait" branch; two of them sat silent for four hours on
# `NEXT: request-review`. pr-sweep.sh inverts the default: only merged, merge
# and the named waiting actions are handled, everything else is an attention
# stop. These cases pin each branch of that dispatch.
#
# Runs pr-sweep.sh against a stubbed pr-status.sh and pr-merge.sh (both are
# resolved next to the script, so it is copied into the stub directory) and a
# stubbed `sleep`, so it needs no network, no repository and no time. Every
# run is bounded by `timeout`: a mutation that turns a stop into a wait then
# fails as exit 124 instead of hanging the suite.

set -uo pipefail

REAL="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/skills/git-workflow/scripts/pr-sweep.sh"
STUB_ROOT="$(mktemp -d)"
trap 'rm -rf "$STUB_ROOT"' EXIT

fail=0
check() { # check <name> <expected> <actual>
    if [ "$2" = "$3" ]; then
        echo "  ok   $1"
    else
        echo "  FAIL $1: expected '$2', got '$3'"
        fail=1
    fi
}

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

# A fresh stub directory per case, so no counter or log leaks between cases.
#   setup
setup() {
    D="$STUB_ROOT/case$((++CASE_N))"
    mkdir -p "$D/seq" "$D/bin"
    cp "$REAL" "$D/pr-sweep.sh"

    # pr-status.sh stub: answers from $D/seq/<owner>_<repo>-<n>, one line per
    # call, the last line repeating once the sequence is used up. A line FAIL
    # exits 2 with a message on stderr, like a failed GraphQL read.
    cat > "$D/pr-status.sh" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$D/status.log"
repo="\$2"; n="\$3"
f="$D/seq/\${repo//\//_}-\$n"
c="\$f.count"
i=\$(( \$(cat "\$c" 2>/dev/null || echo 0) + 1 ))
echo "\$i" > "\$c"
total=\$(wc -l < "\$f")
[ "\$i" -le "\$total" ] || i=\$total
line=\$(head -n "\$i" "\$f" | tail -n 1)
if [ "\$line" = FAIL ]; then
  echo "pr-status: GraphQL query failed" >&2
  exit 2
fi
printf '%s\n' "\$line"
STUB

    # pr-merge.sh stub: logs its arguments and exits with the next code from
    # $D/merge.rc (one per call, last repeating; 0 when absent).
    cat > "$D/pr-merge.sh" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$D/merge.log"
c="$D/merge.count"
i=\$(( \$(cat "\$c" 2>/dev/null || echo 0) + 1 ))
echo "\$i" > "\$c"
rc=0
if [ -f "$D/merge.rc" ]; then
  total=\$(wc -l < "$D/merge.rc")
  [ "\$i" -le "\$total" ] || i=\$total
  rc=\$(head -n "\$i" "$D/merge.rc" | tail -n 1)
fi
echo "pr-merge: stub rc \$rc"
echo "  wait with: pr-status.sh --watch"
exit "\$rc"
STUB

    # sleep stub: the interval is real in production and nothing here.
    cat > "$D/bin/sleep" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$D/sleep.log"
STUB
    chmod +x "$D/pr-status.sh" "$D/pr-merge.sh" "$D/bin/sleep" "$D/pr-sweep.sh"
    : > "$D/list"
}
CASE_N=0

# st <state> <action> [why] -> one pr-status.sh --json line
st() { printf '{"state":"%s","next":{"action":"%s","why":"%s"}}\n' "$1" "$2" "${3:-reason}"; }

pr() { # pr <owner/repo> <n> <line>...   (lines of the pr-status sequence)
    local repo="$1" n="$2"; shift 2
    printf '%s %s\n' "$repo" "$n" >> "$D/list"
    printf '%s\n' "$@" > "$D/seq/${repo//\//_}-$n"
}

run() { # run [extra args] -> sets OUT, RC
    RC=0
    OUT=$(PATH="$D/bin:$PATH" timeout 20 bash "$D/pr-sweep.sh" --attention "$D/attn" "$@" "$D/list" 2>&1) || RC=$?
}

calls() { if [ -f "$1" ]; then wc -l < "$1" | tr -d ' '; else echo 0; fi; }

MERGED="$(st MERGED none 'PR is MERGED')"

echo "case 1: NEXT merge runs pr-merge.sh, then the merged PR ends the sweep"
setup
pr o/r 1 "$(st OPEN merge clean)" "$MERGED"
run
check "exit 0" "0" "$RC"
check "pr-merge.sh called once" "1" "$(calls "$D/merge.log")"
check "pr-merge.sh arguments" "-R o/r 1" "$(cat "$D/merge.log" 2>/dev/null)"
check "pr-status.sh arguments" "-R o/r 1 --json" "$(head -n 1 "$D/status.log")"
check "last line" "ALL MERGED" "$(printf '%s\n' "$OUT" | tail -n 1)"
says "rc of pr-merge.sh is logged" "pr-merge.sh rc=0" "$OUT"

echo "case 2: an already merged PR is done without a merge call"
setup
pr o/r 2 "$MERGED"
run
check "exit 0" "0" "$RC"
check "pr-merge.sh not called" "0" "$(calls "$D/merge.log")"
check "one read" "1" "$(calls "$D/status.log")"
check "last line" "ALL MERGED" "$(printf '%s\n' "$OUT" | tail -n 1)"
check "attention file empty" "" "$(cat "$D/attn")"

echo "case 3: NEXT request-review stops with an attention line"
setup
pr o/r 3 "$(st OPEN request-review 'no review on the current head')"
run
check "exit 3" "3" "$RC"
check "attention line" "o/r 3 NEXT: request-review — no review on the current head" "$(cat "$D/attn")"
check "pr-merge.sh not called" "0" "$(calls "$D/merge.log")"
check "read once, not waited on" "1" "$(calls "$D/status.log")"
says_not "no ALL MERGED" "ALL MERGED" "$OUT"

echo "case 4: an action this script does not know stops the sweep"
setup
pr o/r 4 "$(st OPEN frobnicate 'added in a later pr-status.sh')"
run
check "exit 3" "3" "$RC"
check "attention line" "o/r 4 NEXT: frobnicate — added in a later pr-status.sh" "$(cat "$D/attn")"
check "read once, not waited on" "1" "$(calls "$D/status.log")"

echo "case 5: a failed read once keeps waiting"
setup
pr o/r 5 FAIL "$(st OPEN wait 'checks running')" "$MERGED"
run
check "exit 0" "0" "$RC"
check "three reads" "3" "$(calls "$D/status.log")"
says "the failure is logged" "probe failed once" "$OUT"
check "attention file empty" "" "$(cat "$D/attn")"

echo "case 6: a failed read on two consecutive passes stops"
setup
pr o/r 6 FAIL FAIL "$MERGED"
run
check "exit 3" "3" "$RC"
check "two reads" "2" "$(calls "$D/status.log")"
says "attention names the cause" "o/r 6 pr-status.sh unreadable on two consecutive passes: exit 2: pr-status: GraphQL query failed" "$(cat "$D/attn")"

echo "case 7: failures that are not consecutive keep waiting"
setup
pr o/r 7 FAIL "$(st OPEN wait)" FAIL "$MERGED"
run
check "exit 0" "0" "$RC"
check "four reads" "4" "$(calls "$D/status.log")"

echo "case 8: rules-unavailable counts as a failed read"
setup
pr o/r 8 "$(st OPEN rules-unavailable 'could not read rules')" "$(st OPEN rules-unavailable 'could not read rules')"
run
check "exit 3" "3" "$RC"
says "attention names the action" "NEXT: rules-unavailable — could not read rules" "$(cat "$D/attn")"
check "two reads" "2" "$(calls "$D/status.log")"

echo "case 9: an attention stop finishes the pass before exiting"
setup
pr o/a 1 "$(st OPEN request-review 'no review')"
pr o/b 2 "$(st OPEN merge clean)" "$MERGED"
run
check "exit 3" "3" "$RC"
check "the second PR was still merged" "-R o/b 2" "$(cat "$D/merge.log" 2>/dev/null)"
check "only the first PR in the attention file" "o/a 1 NEXT: request-review — no review" "$(cat "$D/attn")"

echo "case 10: three identical waits log one line"
setup
pr o/r 10 "$(st OPEN wait 'checks running')" "$(st OPEN wait 'checks running')" "$(st OPEN wait 'checks running')" "$MERGED"
run
check "exit 0" "0" "$RC"
check "one waiting line" "1" "$(printf '%s\n' "$OUT" | grep -c 'waiting: NEXT: wait')"
check "slept between passes" "3" "$(calls "$D/sleep.log")"

echo "case 11: every named waiting action keeps waiting"
setup
pr o/r 11 "$(st OPEN wait)" "$(st OPEN await-review)" "$(st OPEN await-checks)" "$(st OPEN await-capacity)" "$MERGED"
run
check "exit 0" "0" "$RC"
check "five reads" "5" "$(calls "$D/status.log")"
check "attention file empty" "" "$(cat "$D/attn")"

echo "case 12: a closed, unmerged PR stops the sweep"
setup
pr o/r 12 "$(st CLOSED none 'PR is CLOSED')"
run
check "exit 3" "3" "$RC"
check "attention line" "o/r 12 NEXT: none — PR is CLOSED" "$(cat "$D/attn")"

echo "case 13: pr-merge.sh rc 1 reads again, rc 2 stops"
setup
pr o/r 13 "$(st OPEN merge clean)" "$(st OPEN merge clean)" "$(st OPEN merge clean)"
printf '1\n2\n' > "$D/merge.rc"
run
check "exit 3" "3" "$RC"
check "two merge attempts" "2" "$(calls "$D/merge.log")"
says "rc 1 logged" "pr-merge.sh rc=1" "$OUT"
says "rc 2 in attention" "o/r 13 pr-merge.sh rc=2" "$(cat "$D/attn")"
says "rc 2 attention keeps the result line" "pr-merge: stub rc 2 wait with" "$(cat "$D/attn")"
says "rc 1 log keeps the result line" "pr-merge.sh rc=1 (gate shut, reading again next pass): pr-merge: stub rc 1" "$OUT"

echo "case 14: NEXT merge again after an enqueue that returned 0 stops"
setup
pr o/r 14 "$(st OPEN merge clean)" "$(st OPEN wait 'in the merge queue')" "$(st OPEN merge clean)"
run
check "exit 3" "3" "$RC"
check "pr-merge.sh called once only" "1" "$(calls "$D/merge.log")"
says "attention names the queue" "probably left the merge queue" "$(cat "$D/attn")"

echo "case 15: the overall timeout exits 4 and names the open PR"
setup
pr o/r 15 "$(st OPEN wait 'checks running')"
run --timeout 0
check "exit 4" "4" "$RC"
says "timeout line" "TIMEOUT" "$OUT"
says "open PR listed with its last state" "o/r#15 last: wait" "$OUT"
says_not "no ALL MERGED" "ALL MERGED" "$OUT"

echo "case 16: an empty list is an input error, never ALL MERGED"
setup
printf '# only a comment\n\n' > "$D/list"
run
check "exit 2" "2" "$RC"
says_not "no ALL MERGED" "ALL MERGED" "$OUT"
check "nothing read" "0" "$(calls "$D/status.log")"

echo "case 17: a malformed line is rejected with its line number"
setup
printf 'o/r 1\nnot-a-repo 2\n' > "$D/list"
run
check "exit 2" "2" "$RC"
says "line number named" "list:2:" "$OUT"

echo "case 18: comments and blank lines are ignored"
setup
pr o/r 18 "$MERGED"
printf '# header\n\no/r 18  # trailing comment\n' > "$D/list"
run
check "exit 0" "0" "$RC"
check "one read" "1" "$(calls "$D/status.log")"

if [ "$fail" -eq 0 ]; then
    echo "all pass"
else
    echo "FAILURES"
    exit 1
fi
