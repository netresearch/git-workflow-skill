#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: Netresearch DTT GmbH
# Regression test: pr-merge.sh must not report an outcome it did not observe.
#
# `gh pr merge <n> --merge` on a merge-queue repository prints its usual success
# line and exits 0 while adding nothing to the queue when an auto-merge request
# is already attached to the PR. pr-merge.sh relayed that as "queued (--merge,
# strategy set by the queue)" — a state that did not exist, and hours of
# misdiagnosis. It now reads the PR back and only claims what it saw.
#
# Runs pr-merge.sh against a stubbed `gh` and a stubbed pr-status.sh, so it needs
# no network and no repo. `sleep` is stubbed away too: the bounded poll between
# probes is real, and waiting it out would add ~8s per failing case here.

set -uo pipefail

REAL="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/skills/git-workflow/scripts/pr-merge.sh"
STUB_ROOT="$(mktemp -d)"
trap 'rm -rf "$STUB_ROOT"' EXIT
# A space in the path: the waiter line must stay a runnable command.
STUB_DIR="$STUB_ROOT/with space"
mkdir -p "$STUB_DIR"

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

# pr-status.sh is resolved next to pr-merge.sh, which is why the script under
# test is copied into the stub directory rather than run in place.
#   make_status <queue_active>
make_status() {
    cat > "$STUB_DIR/status.json" <<JSON
{
  "repo": "o/r", "number": 559, "queue_active": $1,
  "merge_methods": ["merge", "rebase"],
  "head": "feature/x", "cross_repository": false,
  "next": {"action": "merge", "why": "clean", "method": "--merge"}
}
JSON
    # Every call without --json is logged to status.log: --wait runs the
    # one-shot gate read after the entry left the queue or the wait ran out.
    cat > "$STUB_DIR/pr-status.sh" <<STATUS
#!/usr/bin/env bash
case " \$* " in
  *" --json "*) ;;
  *) printf '%s\n' "\$*" >> "$STUB_DIR/status.log"; echo "NEXT: stub"; exit 0 ;;
esac
cat "$STUB_DIR/status.json"
STATUS
    chmod +x "$STUB_DIR/pr-status.sh"
}

# `gh` stub. Every invocation is appended to calls.log so the poll can be
# asserted on. `gh pr merge` always succeeds — that is the whole premise of the
# bug. `gh api graphql` answers the file named by $STUB_DIR/graphql.json, or
# exits non-zero when that file is absent (the unreachable-API case).
make_gh() {
    cat > "$STUB_DIR/gh" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$1 \$2" >> "$STUB_DIR/calls.log"
if [ "\$1 \$2" = "pr merge" ]; then
  echo "Merging pull request #559"
  exit 0
fi
# The dependent-PR query pr-merge.sh makes before merging: nothing is stacked.
if [ "\$1 \$2" = "pr list" ]; then
  exit 0
fi
# A slow API, for the wall-clock case: each GraphQL read takes 2 s.
if [ -f "$STUB_DIR/slow" ]; then /bin/sleep 2; fi
n=\$(grep -c '^api graphql\$' "$STUB_DIR/calls.log")
if [ -f "$STUB_DIR/graphql.\$n.json" ]; then
  cat "$STUB_DIR/graphql.\$n.json"; exit 0
fi
if [ -f "$STUB_DIR/graphql.json" ]; then
  cat "$STUB_DIR/graphql.json"; exit 0
fi
echo "gh: could not reach api.github.com" >&2
exit 1
STUB
    chmod +x "$STUB_DIR/gh"
    # No-op sleep: the poll's timing is not what these cases are about.
    printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB_DIR/sleep"
    chmod +x "$STUB_DIR/sleep"
    : > "$STUB_DIR/calls.log"
}

#   make_pr <file> <state> <isInMergeQueue> <autoMergeLogin|->
make_pr() {
    local auto='null'
    [ "$4" = "-" ] || auto="{\"enabledBy\":{\"login\":\"$4\"}}"
    cat > "$STUB_DIR/$1" <<JSON
{"data":{"repository":{"pullRequest":{
  "state":"$2","isInMergeQueue":$3,"autoMergeRequest":$auto}}}}
JSON
}

reset() { rm -f "$STUB_DIR"/graphql*.json "$STUB_DIR/status.log"; }

run() { PATH="$STUB_DIR:$PATH" bash "$SCRIPT" -R o/r 559 2>"$STUB_DIR/err"; }
graphql_calls() { grep -c '^api graphql$' "$STUB_DIR/calls.log"; }

echo "case 1: queue repo, entry really registered — reports queued, exit 0"
make_status true; make_gh; reset
make_pr graphql.json OPEN true -
out=$(run); rc=$?
check "exit code" "0" "$rc"
says "reports queued" "559 queued (--merge, strategy set by the queue)" "$out"
# The next step after a queued entry is waiting for it. Without a named waiter
# the caller hand-wrote a poll on `gh pr view --json isInMergeQueue`, a field
# that exists only in GraphQL.
says "names the waiter" "wait with: $(printf '%q' "$STUB_DIR/pr-status.sh") -R o/r 559 --watch" "$out"

echo "case 2: queue repo, nothing enqueued, auto-merge attached — FAILS, exit 2"
make_status true; make_gh; reset
make_pr graphql.json OPEN false renovate
out=$(run); rc=$?
err=$(cat "$STUB_DIR/err")
check "exit code" "2" "$rc"
check "stdout silent" "" "$out"
says     "names the failure"      "failed: gh pr merge --merge exited 0" "$err"
says     "names the observation"  "not in the merge queue (state=OPEN, isInMergeQueue=false)" "$err"
says     "names the likely cause" "auto-merge request enabled by renovate" "$err"
says     "offers --disable-auto"  "gh pr merge 559 --repo o/r --disable-auto" "$err"
says_not "does not claim queued"  "queued (--merge" "$out$err"

echo "case 3: queue repo, nothing enqueued, NO auto-merge request — no false cause"
make_status true; make_gh; reset
make_pr graphql.json OPEN false -
out=$(run); rc=$?
err=$(cat "$STUB_DIR/err")
check "exit code" "2" "$rc"
says     "rules the cause out" "No auto-merge request is attached" "$err"
says_not "does not invent an enabler" "enabled by" "$err"

echo "case 4: no queue, PR really merged — reports merged, exit 0"
make_status false; make_gh; reset
make_pr graphql.json MERGED false -
out=$(run); rc=$?
check "exit code" "0" "$rc"
says "reports merged" "559 merged (--merge)" "$out"
says_not "no waiter once merged" "wait with:" "$out"

# The same swallowed-call shape without a queue: exit 0 from gh, PR still open.
echo "case 5: no queue, PR still OPEN — must not claim merged"
make_status false; make_gh; reset
make_pr graphql.json OPEN false -
out=$(run); rc=$?
err=$(cat "$STUB_DIR/err")
check "exit code" "2" "$rc"
says_not "does not claim merged" "merged (--merge)" "$out"
says     "names the observation" "not merged (state=OPEN)" "$err"

# A queue entry is registered asynchronously. Giving up on the first read would
# report a failure for a PR that is on its way into the queue.
echo "case 6: entry appears on the third probe — polled, then reported queued"
make_status true; make_gh; reset
make_pr graphql.1.json OPEN false -
make_pr graphql.2.json OPEN false -
make_pr graphql.3.json OPEN true  -
out=$(run); rc=$?
check "exit code"      "0" "$rc"
check "probed 3 times" "3" "$(graphql_calls)"
says  "reports queued" "559 queued" "$out"

# The poll must stop on its own. Nothing here ever enqueues, so an unbounded
# loop would hang the suite rather than fail it.
echo "case 7: never enqueued — the poll is bounded"
make_status true; make_gh; reset
make_pr graphql.json OPEN false -
run >/dev/null; rc=$?
check "exit code"  "2" "$rc"
check "5 attempts" "5" "$(graphql_calls)"

# An unreachable API says something about the request, not about the PR. Folding
# it into "not enqueued" would put a transport failure on the record as a fact
# about GitHub state — and naming --disable-auto there sends the operator to
# mutate a PR whose state was never read.
echo "case 8: GraphQL unreachable — reported as unknown, not as not-enqueued"
make_status true; make_gh; reset
run >/dev/null; rc=$?
err=$(cat "$STUB_DIR/err")
check "exit code" "2" "$rc"
says     "says the outcome is unknown" "the outcome could not be" "$err"
says_not "does not assert queue state" "isInMergeQueue=" "$err"
says_not "does not suggest --disable-auto" "--disable-auto" "$err"

# The gate check runs before anything is called; verification must not have
# moved it or added an API call to a refusal.
echo "case 9: gate shut — still exit 1, and gh is never called"
make_gh; reset
cat > "$STUB_DIR/status.json" <<'JSON'
{
  "repo": "o/r", "number": 559, "queue_active": false,
  "merge_methods": ["merge"],
  "next": {"action": "fix-ci", "why": "required check(s) failing: build"}
}
JSON
run >/dev/null; rc=$?
err=$(cat "$STUB_DIR/err")
check "exit code"    "1" "$rc"
check "no gh calls"  "0" "$(wc -l < "$STUB_DIR/calls.log")"
says  "names the gate" "not merging o/r#559 — fix-ci" "$err"

# A dry run reads (the dependent-PR query runs for a queued merge too, #460)
# but writes nothing: no merge, no retarget, no comment.
echo "case 10: --dry-run prints the command and writes nothing"
make_status true; make_gh; reset
out=$(PATH="$STUB_DIR:$PATH" bash "$SCRIPT" -R o/r 559 --dry-run 2>&1); rc=$?
check "exit code"   "0" "$rc"
check "no gh write calls" "0" "$(grep -cE '^pr (merge|edit|comment)' "$STUB_DIR/calls.log")"
check "only the dependent query was read" "pr list" "$(tr -d '\n' < "$STUB_DIR/calls.log")"
says  "prints the merge command" "gh pr merge 559 --repo o/r --merge" "$out"

# --wait: queueing and waiting in one call, so the caller writes no poll of its
# own. It reads state and isInMergeQueue until the PR merged or left the queue.
runw() { PATH="$STUB_DIR:$PATH" bash "$SCRIPT" -R o/r 559 --wait "$@" 2>"$STUB_DIR/err"; }
status_calls() { if [ -f "$STUB_DIR/status.log" ]; then wc -l < "$STUB_DIR/status.log" | tr -d ' '; else echo 0; fi; }

echo "case 11: --wait, queued, then merged — reports merged, exit 0"
make_status true; make_gh; reset
make_pr graphql.1.json OPEN true -
make_pr graphql.2.json OPEN true -
make_pr graphql.3.json MERGED false -
out=$(runw); rc=$?
check "exit code" "0" "$rc"
check "read until merged" "3" "$(graphql_calls)"
check "no gate read needed" "0" "$(status_calls)"
says     "reports merged through the queue" "559 merged (--merge, through the merge queue)" "$out"
says_not "no waiter line" "wait with:" "$out"

echo "case 12: --wait, entry dropped out of the queue — exit 1, names the next step"
make_status true; make_gh; reset
make_pr graphql.1.json OPEN true -
make_pr graphql.json OPEN false -
out=$(runw); rc=$?
err=$(cat "$STUB_DIR/err")
check "exit code" "1" "$rc"
check "drop confirmed on a second read" "3" "$(graphql_calls)"
check "gate read once" "1" "$(status_calls)"
says     "names the drop" "left the merge queue without merging (state=OPEN)" "$err"
says     "passes the gate on" "NEXT: stub" "$err"
says_not "does not claim merged" "merged (" "$out"

# The defect the first version had: pr-status.sh --watch returns on
# address-comments, rebase or fix-ci while the entry is still queued. A wait
# keyed on the PR itself holds on until --max-wait.
echo "case 13: --wait, still queued for the whole --max-wait — exit 1, bounded"
make_status true; make_gh; reset
make_pr graphql.json OPEN true -
out=$(runw --interval 20 --max-wait 40); rc=$?
err=$(cat "$STUB_DIR/err")
check "exit code" "1" "$rc"
check "1 enqueue read + 3 wait reads" "4" "$(graphql_calls)"
says  "names the timeout" "still in the merge queue after 40s" "$err"
check "gate read once" "1" "$(status_calls)"

echo "case 14: --wait, a failed read in between is not an outcome"
make_status true; make_gh; reset
make_pr graphql.1.json OPEN true -
make_pr graphql.3.json MERGED false -
out=$(runw); rc=$?
check "exit code" "0" "$rc"
says "reports merged" "559 merged (--merge, through the merge queue)" "$out"

echo "case 15: --wait, the last read failed when the wait ran out — exit 2, unknown"
make_status true; make_gh; reset
make_pr graphql.1.json OPEN true -
out=$(runw --max-wait 0); rc=$?
err=$(cat "$STUB_DIR/err")
check "exit code" "2" "$rc"
says     "says the outcome is unknown" "the last read of the pull request failed" "$err"
says_not "does not claim merged" "merged (" "$out"

echo "case 16: --wait without a queue — merged directly, no wait reads"
make_status false; make_gh; reset
make_pr graphql.json MERGED false -
out=$(runw); rc=$?
check "exit code" "0" "$rc"
check "one read" "1" "$(graphql_calls)"
says "reports merged" "559 merged (--merge)" "$out"

echo "case 17: --max-wait without --wait is refused before anything runs"
make_status true; make_gh; reset
PATH="$STUB_DIR:$PATH" bash "$SCRIPT" -R o/r 559 --max-wait 10 >/dev/null 2>"$STUB_DIR/err"; rc=$?
check "exit code" "2" "$rc"
check "no gh calls" "0" "$(wc -l < "$STUB_DIR/calls.log" | tr -d ' ')"
says  "names the rule" "only apply with --wait" "$(cat "$STUB_DIR/err")"

# GitHub can put a dropped entry back by itself while auto-merge is armed;
# re-queueing by hand would cancel that run. One read outside the queue is
# therefore not yet a drop.
echo "case 18: --wait, out of the queue once, back in, then merged — exit 0"
make_status true; make_gh; reset
make_pr graphql.1.json OPEN true -
make_pr graphql.2.json OPEN false -
make_pr graphql.3.json OPEN true -
make_pr graphql.4.json MERGED false -
out=$(runw); rc=$?
check "exit code" "0" "$rc"
check "no gate read" "0" "$(status_calls)"
says  "reports merged" "559 merged (--merge, through the merge queue)" "$out"

echo "case 19: a leading zero is refused (bash reads 08 as bad octal)"
make_status true; make_gh; reset
PATH="$STUB_DIR:$PATH" bash "$SCRIPT" -R o/r 559 --wait --interval 08 >/dev/null 2>"$STUB_DIR/err"; rc=$?
check "exit code" "2" "$rc"
check "no gh calls" "0" "$(wc -l < "$STUB_DIR/calls.log" | tr -d ' ')"
says  "names the rule" "without a leading zero" "$(cat "$STUB_DIR/err")"

echo "case 20: --max-wait not a multiple of --interval — the last sleep is shortened"
make_status true; make_gh; reset
make_pr graphql.json OPEN true -
cat > "$STUB_DIR/sleep" <<SLEEP
#!/usr/bin/env bash
printf '%s\n' "\$1" >> "$STUB_DIR/sleep.log"
SLEEP
chmod +x "$STUB_DIR/sleep"; rm -f "$STUB_DIR/sleep.log"
out=$(runw --interval 20 --max-wait 30); rc=$?
check "exit code" "1" "$rc"
check "sleeps 20 then 10" "20 10" "$(tr '\n' ' ' < "$STUB_DIR/sleep.log" | sed 's/ $//')"

echo "case 21: --wait, out, in, out, in, merged — a single read outside never adds up"
make_status true; make_gh; reset
make_pr graphql.1.json OPEN true -
make_pr graphql.2.json OPEN false -
make_pr graphql.3.json OPEN true -
make_pr graphql.4.json OPEN false -
make_pr graphql.5.json OPEN true -
make_pr graphql.6.json MERGED false -
out=$(runw); rc=$?
check "exit code" "0" "$rc"
check "no gate read" "0" "$(status_calls)"

echo "case 22: --wait, one failed read early, then queued to the end — exit 1, not 2"
make_status true; make_gh; reset
make_pr graphql.1.json OPEN true -
make_pr graphql.3.json OPEN true -
make_pr graphql.4.json OPEN true -
out=$(runw --interval 20 --max-wait 40); rc=$?
err=$(cat "$STUB_DIR/err")
check "exit code" "1" "$rc"
says "names the timeout" "still in the merge queue after 40s" "$err"

# The wall clock bounds the wait too, including the time the reads take. Here
# every read takes 2 s and the sleeps are real: counting only the sleeps would
# run for about 8 s; the deadline stops it after about 4 s (the enqueue read,
# then one wait read past the 2 s limit).
echo "case 23: --wait is bounded by the wall clock, not only by the sum of sleeps"
make_status true; make_gh; reset
make_pr graphql.json OPEN true -
printf '#!/usr/bin/env bash\nexec /bin/sleep "$@"\n' > "$STUB_DIR/sleep"
chmod +x "$STUB_DIR/sleep"
: > "$STUB_DIR/slow"
t0=$SECONDS
out=$(runw --interval 1 --max-wait 2); rc=$?
took=$((SECONDS - t0))
rm -f "$STUB_DIR/slow"
check "exit code" "1" "$rc"
if [ "$took" -le 5 ]; then echo "  ok   stopped after $took seconds"; else echo "  FAIL ran $took seconds, expected about 4"; fail=1; fi

if [ "$fail" -eq 0 ]; then
    echo "all pass"
else
    echo "FAILURES"
    exit 1
fi
