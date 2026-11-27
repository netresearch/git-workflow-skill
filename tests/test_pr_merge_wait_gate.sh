#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: Netresearch DTT GmbH
# Regression test for #496: pr-merge.sh --wait must wait on a waiting gate step.
#
# With --wait, pr-merge.sh used to exit 1 at once whenever pr-status.sh answered
# a waiting step: an entry already in the merge queue, a bot review in flight,
# a non-required check still running. The refusal ran before the wait. Now a
# waiting step is re-read every --interval seconds until it answers merge (then
# merge), the PR is already queued (then the queue wait, without enqueueing
# again), or another step (exit 1), all within --max-wait.
#
# Runs pr-merge.sh against a stubbed `gh`, a stubbed pr-status.sh and a stubbed
# `sleep` that only logs, so it needs no network and does not wait.

set -uo pipefail

REAL="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/skills/git-workflow/scripts/pr-merge.sh"
STUB_DIR="$(mktemp -d)"
trap 'rm -rf "$STUB_DIR"' EXIT
SCRIPT="$STUB_DIR/pr-merge.sh"
cp "$REAL" "$SCRIPT"

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

# pr-status.sh stub. The n-th --json call answers status.<n>.json if it exists,
# else status.json; status.<n>.fail makes the n-th read fail. Calls without
# --json (the one-shot gate print) go to status.log.
cat > "$STUB_DIR/pr-status.sh" <<STATUS
#!/usr/bin/env bash
case " \$* " in
  *" --json "*) ;;
  *) printf '%s\n' "\$*" >> "$STUB_DIR/status.log"; echo "NEXT: stub"; exit 0 ;;
esac
echo x >> "$STUB_DIR/json.log"
n=\$(wc -l < "$STUB_DIR/json.log" | tr -d ' ')
if [ -f "$STUB_DIR/status.\$n.fail" ]; then echo "pr-status: GraphQL error" >&2; exit 1; fi
if [ -f "$STUB_DIR/status.\$n.json" ]; then cat "$STUB_DIR/status.\$n.json"; exit 0; fi
cat "$STUB_DIR/status.json"
STATUS
chmod +x "$STUB_DIR/pr-status.sh"

# gh stub: every call is logged; pr merge succeeds; pr list finds nothing
# stacked; api graphql answers graphql.<n>.json or graphql.json, or fails.
cat > "$STUB_DIR/gh" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$1 \$2" >> "$STUB_DIR/calls.log"
case "\$1 \$2" in
  "pr merge") echo "Merging pull request #745"; exit 0 ;;
  "pr list") exit 0 ;;
  "pr comment") exit 0 ;;
  "api user") echo "me"; exit 0 ;;
esac
n=\$(grep -c '^api graphql\$' "$STUB_DIR/calls.log")
if [ -f "$STUB_DIR/graphql.\$n.json" ]; then cat "$STUB_DIR/graphql.\$n.json"; exit 0; fi
if [ -f "$STUB_DIR/graphql.json" ]; then cat "$STUB_DIR/graphql.json"; exit 0; fi
echo "gh: could not reach api.github.com" >&2
exit 1
STUB
chmod +x "$STUB_DIR/gh"

cat > "$STUB_DIR/sleep" <<SLEEP
#!/usr/bin/env bash
printf '%s\n' "\$1" >> "$STUB_DIR/sleep.log"
SLEEP
chmod +x "$STUB_DIR/sleep"

reset() {
    rm -f "$STUB_DIR"/status*.json "$STUB_DIR"/status.*.fail "$STUB_DIR"/graphql*.json \
          "$STUB_DIR/status.log" "$STUB_DIR/json.log" "$STUB_DIR/sleep.log"
    : > "$STUB_DIR/calls.log"
}

# st <file> <action> <why> [queue_active] [queue_entry-json|null] [state] [extra-json]
# head and base are left out on purpose: empty trailing fields must not shift
# the queue fields read before them.
st() {
    local extra='"x": 0'
    [ -z "${7:-}" ] || extra="$7"
    cat > "$STUB_DIR/$1" <<JSON
{
  "repo": "o/r", "number": 745, "state": "${6:-OPEN}",
  "queue_active": ${4:-false}, "queue_entry": ${5:-null},
  "merge_methods": ["merge", "rebase"], "cross_repository": false,
  "author": "me", "headOid": "499b3ea8deadbeef", $extra,
  "next": {"action": "$2", "why": "$3", "method": "--merge"}
}
JSON
}
#   pr <file> <state> <isInMergeQueue>
pr() {
    cat > "$STUB_DIR/$1" <<JSON
{"data":{"repository":{"pullRequest":{"state":"$2","isInMergeQueue":$3,"autoMergeRequest":null}}}}
JSON
}

run() { PATH="$STUB_DIR:$PATH" bash "$SCRIPT" -R o/r 745 "$@" 2>"$STUB_DIR/err"; }
gate_reads() { if [ -f "$STUB_DIR/json.log" ]; then wc -l < "$STUB_DIR/json.log" | tr -d ' '; else echo 0; fi; }
sleeps() { if [ -f "$STUB_DIR/sleep.log" ]; then tr '\n' ' ' < "$STUB_DIR/sleep.log" | sed 's/ $//'; fi; }
merges() { grep -c '^pr merge$' "$STUB_DIR/calls.log"; }
calls() { tr '\n' ' ' < "$STUB_DIR/calls.log" | sed 's/ $//'; }

QWHY='already in the merge queue at position 1 (AWAITING_CHECKS) — the queue merges it once its own checks pass'
QENTRY='{"position": 1, "state": "AWAITING_CHECKS", "eta": null}'
RWHY='Copilot review already requested for 499b3ea8 and not delivered yet — waiting, not re-requesting'
UWHY='UNSTABLE while 1 non-required check(s) have not finished'

# The issue's first reproduction: the entry was queued before this call.
echo "case 1: already queued + --wait — waits for the entry, reports merged, never enqueues"
reset
st status.json wait "$QWHY" true "$QENTRY"
pr graphql.1.json OPEN true
pr graphql.2.json MERGED false
out=$(run --wait); rc=$?
check "exit code" "0" "$rc"
says  "reports merged" "745 merged (through the merge queue)" "$out"
says  "says it does not enqueue again" "already in the merge queue — waiting for it, not enqueueing again" "$(cat "$STUB_DIR/err")"
check "no gh pr merge, no dependent query" "api graphql api graphql" "$(calls)"
check "one gate read" "1" "$(gate_reads)"
check "one sleep between the two queue reads" "20" "$(sleeps)"

echo "case 2: already queued without --wait — unchanged: exit 1 at once"
reset
st status.json wait "$QWHY" true "$QENTRY"
run >/dev/null; rc=$?
check "exit code" "1" "$rc"
check "no gh calls" "" "$(calls)"
says  "names the gate" "not merging o/r#745 — wait: already in the merge queue" "$(cat "$STUB_DIR/err")"

# The issue's second reproduction: a bot review in flight.
echo "case 3: await-review turns into merge on the third read — merges once, exit 0"
reset
st status.1.json await-review "$RWHY"
st status.2.json await-review "$RWHY"
st status.json merge clean false null OPEN '"head": "feature/x", "base": "main"'
pr graphql.json MERGED false
out=$(run --wait); rc=$?
err=$(cat "$STUB_DIR/err")
check "exit code" "0" "$rc"
says  "reports merged" "745 merged (--merge)" "$out"
check "three gate reads" "3" "$(gate_reads)"
check "slept twice" "20 20" "$(sleeps)"
check "merged once" "1" "$(merges)"
says  "logs the waiting step" "waiting on o/r#745 — await-review: $RWHY" "$err"

# The issue's third reproduction: a non-required check still running, on a
# merge-queue repository, so the merge enqueues and the queue wait follows.
echo "case 4: UNSTABLE wait turns into merge, enqueued, merged through the queue"
reset
st status.1.json wait "$UWHY" true
st status.json merge clean true null OPEN '"head": "feature/x", "base": "main"'
pr graphql.1.json OPEN true
pr graphql.2.json OPEN true
pr graphql.3.json MERGED false
out=$(run --wait); rc=$?
check "exit code" "0" "$rc"
says  "reports merged through the queue" "745 merged (--merge, through the merge queue)" "$out"
check "merged once" "1" "$(merges)"

echo "case 5: wait turns into another step — exit 1, nothing merged"
reset
st status.1.json wait "$UWHY"
st status.json fix-ci "required check(s) failing: build"
out=$(run --wait); rc=$?
err=$(cat "$STUB_DIR/err")
check "exit code" "1" "$rc"
says  "names the new step" "not merging o/r#745 — fix-ci: required check(s) failing: build" "$err"
check "two gate reads" "2" "$(gate_reads)"
check "nothing merged" "0" "$(merges)"
check "no gh calls" "" "$(calls)"

echo "case 6: still waiting when --max-wait runs out — exit 1, bounded, nothing merged"
reset
st status.json await-review "$RWHY"
out=$(run --wait --interval 20 --max-wait 50); rc=$?
err=$(cat "$STUB_DIR/err")
check "exit code" "1" "$rc"
check "sleeps 20 20 10" "20 20 10" "$(sleeps)"
check "four gate reads" "4" "$(gate_reads)"
check "nothing merged" "0" "$(merges)"
says  "names the timeout" "still await-review: $RWHY after 50s" "$err"
check "logs an unchanged step once" "1" "$(grep -c 'waiting on' "$STUB_DIR/err")"

# One budget for both waits: 20 s for the gate, 20 s in the queue, then out.
echo "case 7: --max-wait covers the gate wait and the queue wait together"
reset
st status.1.json wait "$UWHY" true
st status.json merge clean true null OPEN '"head": "feature/x", "base": "main"'
pr graphql.json OPEN true
out=$(run --wait --interval 20 --max-wait 40); rc=$?
check "exit code" "1" "$rc"
check "sleeps 20 (gate) 20 (queue)" "20 20" "$(sleeps)"
says  "names the timeout" "still in the merge queue after 40s" "$(cat "$STUB_DIR/err")"

echo "case 8: a failed gate read in between is not an outcome"
reset
st status.1.json wait "$UWHY"
touch "$STUB_DIR/status.2.fail"
st status.json merge clean false null OPEN '"head": "feature/x", "base": "main"'
pr graphql.json MERGED false
out=$(run --wait); rc=$?
check "exit code" "0" "$rc"
check "merged once" "1" "$(merges)"

echo "case 9: the last gate read failed when the wait ran out — exit 2, unknown"
reset
st status.1.json wait "$UWHY"
touch "$STUB_DIR/status.2.fail"
out=$(run --wait --interval 20 --max-wait 20); rc=$?
check "exit code" "2" "$rc"
says  "says the read failed" "the last read of the gate failed" "$(cat "$STUB_DIR/err")"
check "nothing merged" "0" "$(merges)"

echo "case 10: merged by someone else while waiting — exit 0, nothing merged by this call"
reset
st status.1.json await-review "$RWHY"
st status.json none "PR is MERGED" false null MERGED
out=$(run --wait); rc=$?
check "exit code" "0" "$rc"
says  "says so" "745 merged while waiting for the gate (not by this call)" "$out"
check "nothing merged" "0" "$(merges)"

echo "case 11: enqueued by auto-merge while waiting — goes to the queue wait, no enqueue"
reset
st status.1.json wait "$UWHY" true
st status.json wait "$QWHY" true "$QENTRY"
pr graphql.json MERGED false
out=$(run --wait); rc=$?
check "exit code" "0" "$rc"
says  "reports merged through the queue" "745 merged (through the merge queue)" "$out"
check "nothing merged by this call" "0" "$(merges)"

echo "case 12: --dry-run --wait on a waiting step — reports, does not wait"
reset
st status.json await-review "$RWHY"
out=$(run --wait --dry-run); rc=$?
check "exit code" "1" "$rc"
check "no sleep" "" "$(sleeps)"
check "one gate read" "1" "$(gate_reads)"

# The attestation is posted for the head the call started on, on the first
# read only — never minted mid-wait.
echo "case 13: --self-reviewed --wait, review in flight turns into request-review — exit 1, no attestation"
reset
st status.1.json await-review "$RWHY"
st status.json request-review "no review on the head"
sed -i 's/"method": "--merge"/"method": "--merge", "reason": "bot-review-unsatisfiable"/' "$STUB_DIR/status.json"
out=$(run --wait --self-reviewed); rc=$?
check "exit code" "1" "$rc"
says  "names the step" "not merging o/r#745 — request-review" "$(cat "$STUB_DIR/err")"
check "no comment, no user lookup" "" "$(calls)"

if [ "$fail" -eq 0 ]; then
    echo "all pass"
else
    echo "FAILURES"
    exit 1
fi
