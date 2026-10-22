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

# The payloads count toward the same limit. Three shapes, each built by
# build_case below:
#   rules  2000 required contexts, none reported: about 60 KB of rules, read
#          by evaluate(); NEXT is await-checks.
#   inv    800 required contexts, all green, BLOCKED and APPROVED: NEXT is
#          investigate, so investigate_evidence() reads the rules (about 50 KB)
#          too, and its evidence block is merged into the answer.
#   empty  the rules endpoint answers 200 with an empty body: the gate must
#          stay unreadable, as it was when the rules went in through
#          --argjson, and never read as "no rules".
STUB_DIR="$WRAP_DIR/stub"; mkdir -p "$STUB_DIR"
cat > "$STUB_DIR/gh" <<STUB
#!/usr/bin/env bash
for a in "\$@"; do
  case "\$a" in
    repos/*/rules/branches/*) cat "$STUB_DIR/rules.json"; exit 0 ;;
    repos/*/branches/*/protection) echo "gh: Branch not protected (HTTP 404)" >&2; exit 1 ;;
    repos/*/commits/*/check-runs*) cat "$STUB_DIR/checkruns.json"; exit 0 ;;
    repos/*/commits/*/check-suites*) cat "$STUB_DIR/checksuites.json"; exit 0 ;;
    repos/*/compare/*) echo '{"ahead_by":1,"behind_by":0}'; exit 0 ;;
  esac
done
cat "$STUB_DIR/graphql.json"
STUB
chmod +x "$STUB_DIR/gh"

build_case() { # build_case rules|inv|empty
    python3 - "$STUB_DIR" "$1" <<'PY'
import sys, json, os
d, shape = sys.argv[1], sys.argv[2]
head = "cddd6f7cf8cedba97886c14dfb65387c53efd2ba"
GHA = 15368
n = {"rules": 2000, "inv": 800}.get(shape, 200)
names = ["ci / PHP 8.4 TYPO3 14.3 job %04d" % i for i in range(n)]
green = shape == "inv"
rules = [{"type": "required_status_checks", "ruleset_id": 1, "parameters": {
             "strict_required_status_checks_policy": False,
             "required_status_checks": [{"context": c, "integration_id": GHA} for c in names]}},
         {"type": "pull_request", "ruleset_id": 2, "parameters": {
             "required_approving_review_count": 1, "dismiss_stale_reviews_on_push": True,
             "required_reviewers": [], "require_code_owner_review": False,
             "require_last_push_approval": False, "required_review_thread_resolution": True,
             "require_extra_approval_for_unattributed_changes": False,
             "allowed_merge_methods": ["merge"]}}]
with open(os.path.join(d, "rules.json"), "w") as fh:
    if shape != "empty":
        json.dump(rules, fh)
rollup = [{"__typename": "CheckRun", "name": c, "conclusion": "SUCCESS", "status": "COMPLETED",
           "detailsUrl": "u", "startedAt": "2026-09-24T10:00:00Z"} for c in names] if green else []
runs = [{"name": c, "status": "completed", "conclusion": "success",
         "started_at": "2026-09-24T10:00:00Z", "app": {"id": GHA}, "check_suite": {"id": 1}}
        for c in names] if green else []
json.dump({"check_runs": runs}, open(os.path.join(d, "checkruns.json"), "w"))
json.dump({"check_suites": [{"id": 1, "conclusion": "success",
                             "app": {"id": GHA, "slug": "github-actions"}}]},
          open(os.path.join(d, "checksuites.json"), "w"))
json.dump({"data": {"viewer": {"login": "someone"}, "repository": {
    "nameWithOwner": "o/r", "autoMergeAllowed": True,
    "mergeCommitAllowed": True, "rebaseMergeAllowed": False, "squashMergeAllowed": False,
    "pullRequest": {
        "number": 1, "title": "t", "state": "OPEN", "isDraft": False, "body": "b",
        "mergeable": "MERGEABLE", "mergeStateStatus": "BLOCKED", "reviewDecision": "APPROVED",
        "mergeQueueEntry": None, "author": {"login": "someone", "__typename": "User"},
        "baseRefName": "main", "headRefName": "f", "headRefOid": head,
        "isCrossRepository": False, "comments": {"nodes": []},
        "reviews": {"nodes": [{"author": {"login": "other"}, "state": "APPROVED",
                               "commit": {"oid": head}, "body": ""}]},
        "reviewRequests": {"nodes": []}, "reviewThreads": {"nodes": []},
        "commits": {"nodes": [{"commit": {"oid": head, "statusCheckRollup": {
            "state": "SUCCESS", "contexts": {"pageInfo": {"hasNextPage": False},
                                             "nodes": rollup}}}}]},
        "allCommits": {"nodes": [{"commit": {"oid": head,
                                             "signature": {"isValid": True}}}]},
    }}}}, open(os.path.join(d, "graphql.json"), "w"))
PY
}

run_case() { # run_case <label> <shape> <expected NEXT, or "unreadable">
    build_case "$2"
    : >"$WRAP_DIR/lengths"; : >"$WRAP_DIR/refused"
    local rc=0 out next
    out="$(XDG_CACHE_HOME="$WRAP_DIR/cache" PATH="$WRAP_DIR:$STUB_DIR:$PATH" \
           bash "$ROOT/skills/git-workflow/scripts/pr-status.sh" -R o/r 1 --json 2>"$WRAP_DIR/err")" || rc=$?
    next=$("$REAL_JQ" -r '.next.action // empty' <<<"$out" 2>/dev/null || true)
    if [ "$(wc -l <"$WRAP_DIR/refused")" -gt 0 ]; then
        echo "  FAIL $1: $(wc -l <"$WRAP_DIR/refused") jq call(s) over $LIMIT characters, longest $(sort -n "$WRAP_DIR/refused" | tail -n 1)"
        fail=1
    elif [ "$3" = unreadable ]; then
        if [ "$rc" -ne 0 ] && [ -z "$next" ]; then
            echo "  ok   $1: unreadable (exit $rc), not read as no rules"
        else
            echo "  FAIL $1: expected an unreadable gate, got exit $rc and NEXT '$next'"
            fail=1
        fi
    elif [ "$next" != "$3" ]; then
        echo "  FAIL $1: expected NEXT $3, got '$next' (exit $rc)"
        sed 's/^/         /' "$WRAP_DIR/err"
        fail=1
    elif [ "$3" = investigate ] && ! "$REAL_JQ" -e '.next.evidence | type == "object"' <<<"$out" >/dev/null 2>&1; then
        echo "  FAIL $1: NEXT is investigate but no evidence block was merged"
        sed 's/^/         /' "$WRAP_DIR/err"
        fail=1
    else
        echo "  ok   $1: NEXT is $next, longest command line $(sort -n "$WRAP_DIR/lengths" | tail -n 1) characters"
    fi
}

run_case "60 KB of rules" rules await-checks
run_case "800 green required contexts, evidence merged" inv investigate
run_case "empty rules answer" empty unreadable

# The programs are found beside the real script, also through a symlink, and a
# copy without them stops at once instead of polling an unreadable gate.
build_case rules
ln -s "$ROOT/skills/git-workflow/scripts/pr-status.sh" "$WRAP_DIR/pr-status-link.sh"
next=$(XDG_CACHE_HOME="$WRAP_DIR/cache" PATH="$WRAP_DIR:$STUB_DIR:$PATH" \
       bash "$WRAP_DIR/pr-status-link.sh" -R o/r 1 --json 2>/dev/null | "$REAL_JQ" -r '.next.action' 2>/dev/null || true)
if [ "$next" = await-checks ]; then
    echo "  ok   through a symlink: the programs are found, NEXT is $next"
else
    echo "  FAIL through a symlink: expected NEXT await-checks, got '$next'"
    fail=1
fi
mkdir -p "$WRAP_DIR/bare"
cp "$ROOT/skills/git-workflow/scripts/pr-status.sh" "$WRAP_DIR/bare/"
rc=0
err=$(XDG_CACHE_HOME="$WRAP_DIR/cache" PATH="$WRAP_DIR:$STUB_DIR:$PATH" \
      timeout 60 bash "$WRAP_DIR/bare/pr-status.sh" -R o/r 1 --watch 2>&1 >/dev/null) || rc=$?
case "$rc:$err" in
    2:*"pr-status-evaluate.jq is missing"*) echo "  ok   without the .jq programs: stops at once (exit 2)" ;;
    *) echo "  FAIL without the .jq programs: exit $rc, stderr: $err"; fail=1 ;;
esac

exit $fail
