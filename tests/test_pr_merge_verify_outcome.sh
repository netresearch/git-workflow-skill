#!/usr/bin/env bash
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

# pr-status.sh is resolved next to pr-merge.sh, which is why the script under
# test is copied into the stub directory rather than run in place.
#   make_status <queue_active>
make_status() {
    cat > "$STUB_DIR/status.json" <<JSON
{
  "repo": "o/r", "number": 559, "queue_active": $1,
  "merge_methods": ["merge", "rebase"],
  "next": {"action": "merge", "why": "clean", "method": "--merge"}
}
JSON
    cat > "$STUB_DIR/pr-status.sh" <<STATUS
#!/usr/bin/env bash
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

reset() { rm -f "$STUB_DIR"/graphql*.json; }

run() { PATH="$STUB_DIR:$PATH" bash "$SCRIPT" -R o/r 559 2>"$STUB_DIR/err"; }
graphql_calls() { grep -c '^api graphql$' "$STUB_DIR/calls.log"; }

echo "case 1: queue repo, entry really registered — reports queued, exit 0"
make_status true; make_gh; reset
make_pr graphql.json OPEN true -
out=$(run); rc=$?
check "exit code" "0" "$rc"
says "reports queued" "559 queued (--merge, strategy set by the queue)" "$out"

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

echo "case 10: --dry-run prints the command and calls nothing"
make_status true; make_gh; reset
out=$(PATH="$STUB_DIR:$PATH" bash "$SCRIPT" -R o/r 559 --dry-run 2>&1); rc=$?
check "exit code"   "0" "$rc"
check "no gh calls" "0" "$(wc -l < "$STUB_DIR/calls.log")"
says  "prints the merge command" "gh pr merge 559 --repo o/r --merge" "$out"

if [ "$fail" -eq 0 ]; then
    echo "all pass"
else
    echo "FAILURES"
    exit 1
fi
