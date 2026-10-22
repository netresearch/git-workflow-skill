#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: Netresearch DTT GmbH
# Regression test: pr-status.sh must run where a whole command line is capped
# at 32767 characters, as Windows caps it (#395).
#
# The jq program of evaluate() was a single-quoted argument of about 90 KB.
# On Linux that fits (one argument may hold 128 KiB, all of them about 2 MiB),
# so every other test passed while the script could not start jq on Windows.
#
# This test puts a `jq` wrapper first on PATH that refuses any invocation whose
# command line exceeds 32767 characters, as CreateProcess does, and runs the
# tests that reach evaluate() and investigate_evidence() under it. The
# wrapper also logs every invocation, so a run where it never fired fails too.
#
# Runs pr-status.sh against stubbed `gh`, so it needs no network and no repo.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WRAP_DIR="$(mktemp -d)"
trap 'rm -rf "$WRAP_DIR"' EXIT

REAL_JQ="$(command -v jq)"
LIMIT=32767

cat > "$WRAP_DIR/jq" <<WRAP
#!/usr/bin/env bash
# Length of the command line CreateProcess would receive: the program name and
# every argument, separated by one space each. Quoting adds to that on
# Windows, so this count is a lower bound.
n=\${#0}
for a in "\$@"; do n=\$((n + 1 + \${#a})); done
echo "\$n" >>"$WRAP_DIR/lengths"
if [ "\$n" -gt $LIMIT ]; then
  echo "\$0: Argument list too long (command line of \$n characters, limit $LIMIT)" >&2
  echo "\$n" >>"$WRAP_DIR/refused"
  exit 126
fi
exec "$REAL_JQ" "\$@"
WRAP
chmod +x "$WRAP_DIR/jq"

fail=0
for t in test_pr_status_large_graphql.sh test_pr_status_investigate_evidence.sh \
         test_pr_status_json_contract.sh; do
    : >"$WRAP_DIR/lengths"; : >"$WRAP_DIR/refused"
    rc=0
    PATH="$WRAP_DIR:$PATH" bash "$ROOT/tests/$t" >"$WRAP_DIR/out" 2>&1 || rc=$?
    calls=$(wc -l <"$WRAP_DIR/lengths")
    refused=$(wc -l <"$WRAP_DIR/refused")
    longest=$(sort -n "$WRAP_DIR/lengths" | tail -n 1)
    if [ "$calls" -eq 0 ]; then
        echo "  FAIL $t: the jq wrapper was never called, so nothing was measured"
        fail=1
    elif [ "$refused" -gt 0 ]; then
        echo "  FAIL $t: $refused jq call(s) over $LIMIT characters, longest $longest"
        fail=1
    elif [ "$rc" -ne 0 ]; then
        echo "  FAIL $t: exit $rc under the wrapper"
        sed 's/^/         /' "$WRAP_DIR/out"
        fail=1
    else
        echo "  ok   $t: $calls jq calls, longest command line $longest characters"
    fi
done

# The payloads count toward the same limit. A branch whose rulesets require
# 2000 status checks answers the rules endpoint with about 60 KB, which must
# reach jq through a file as well.
STUB_DIR="$WRAP_DIR/stub"; mkdir -p "$STUB_DIR"
cat > "$STUB_DIR/gh" <<STUB
#!/usr/bin/env bash
for a in "\$@"; do
  case "\$a" in
    repos/*/rules/branches/*) cat "$STUB_DIR/rules.json"; exit 0 ;;
  esac
done
cat "$STUB_DIR/graphql.json"
STUB
chmod +x "$STUB_DIR/gh"
python3 - "$STUB_DIR" <<'PY'
import sys, json, os
d = sys.argv[1]
head = "deadbeefcafe"
json.dump([{"type": "required_status_checks", "ruleset_id": 1, "parameters": {
    "strict_required_status_checks_policy": False,
    "required_status_checks": [{"context": "required check %04d" % i}
                               for i in range(2000)]}}],
          open(os.path.join(d, "rules.json"), "w"))
json.dump({"data": {"repository": {
    "nameWithOwner": "o/r",
    "mergeCommitAllowed": True, "rebaseMergeAllowed": False, "squashMergeAllowed": False,
    "pullRequest": {
        "number": 1, "title": "t", "state": "OPEN", "isDraft": False,
        "mergeable": "MERGEABLE", "mergeStateStatus": "BLOCKED", "reviewDecision": "APPROVED",
        "author": {"login": "someone"}, "body": "b",
        "baseRefName": "main", "headRefName": "f", "headRefOid": head,
        "isCrossRepository": False,
        "reviews": {"nodes": []}, "reviewRequests": {"nodes": []},
        "reviewThreads": {"nodes": []},
        "commits": {"nodes": [{"commit": {"oid": head, "statusCheckRollup": {
            "state": "SUCCESS", "contexts": {"nodes": []}}}}]},
        "allCommits": {"nodes": [{"commit": {"oid": head,
                                             "signature": {"isValid": True}}}]},
    }}}}, open(os.path.join(d, "graphql.json"), "w"))
PY
: >"$WRAP_DIR/lengths"; : >"$WRAP_DIR/refused"
rc=0
out="$(XDG_CACHE_HOME="$WRAP_DIR/cache" PATH="$WRAP_DIR:$STUB_DIR:$PATH" \
       bash "$ROOT/skills/git-workflow/scripts/pr-status.sh" -R o/r 1 --json 2>"$WRAP_DIR/err")" || rc=$?
refused=$(wc -l <"$WRAP_DIR/refused")
if [ "$refused" -gt 0 ]; then
    echo "  FAIL 60 KB of rules: $refused jq call(s) over $LIMIT characters, longest $(sort -n "$WRAP_DIR/refused" | tail -n 1)"
    fail=1
elif ! "$REAL_JQ" -e '.next.action' <<<"$out" >/dev/null 2>&1; then
    echo "  FAIL 60 KB of rules: no .next.action in the output (exit $rc)"
    sed 's/^/         /' "$WRAP_DIR/err"
    fail=1
else
    echo "  ok   60 KB of rules: read, NEXT is $("$REAL_JQ" -r '.next.action' <<<"$out")"
fi

exit $fail
