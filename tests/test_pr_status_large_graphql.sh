#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: Netresearch DTT GmbH
# Regression test: a GraphQL answer larger than one command-line argument may be
# must still be read.
#
# Linux caps a single argv string at 128 KiB (MAX_ARG_STRLEN). pr-status.sh
# handed the whole GraphQL answer to jq with --argjson, so a pull request with
# long comments or review bodies made jq fail with "Argument list too long" and
# the gate read as UNREADABLE on every poll of --watch. Seen on a pull request
# whose mutation-table comment and CodeRabbit reviews passed that size.
#
# Runs pr-status.sh against a stubbed `gh`, so it needs no network and no repo.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/skills/git-workflow/scripts/pr-status.sh"
STUB_DIR="$(mktemp -d)"
trap 'rm -rf "$STUB_DIR"' EXIT

fail=0

printf '%s\n' '[]' > "$STUB_DIR/rules.json"

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

python3 - "$STUB_DIR/graphql.json" <<'PY'
import sys, json
head = "deadbeefcafe"
json.dump({"data": {"repository": {
    "nameWithOwner": "o/r",
    "mergeCommitAllowed": True, "rebaseMergeAllowed": False, "squashMergeAllowed": False,
    "pullRequest": {
        "number": 1, "title": "t", "state": "OPEN", "isDraft": False,
        "mergeable": "MERGEABLE", "mergeStateStatus": "CLEAN", "reviewDecision": "APPROVED",
        "author": {"login": "someone"},
        # Larger than MAX_ARG_STRLEN (131072 bytes) on its own.
        "body": "x" * 300000,
        "baseRefName": "main", "headRefName": "f", "headRefOid": head,
        "isCrossRepository": False,
        "reviews": {"nodes": []},
        "reviewRequests": {"nodes": []},
        "reviewThreads": {"nodes": []},
        "commits": {"nodes": [{"commit": {"oid": head, "statusCheckRollup": {
            "state": "SUCCESS", "contexts": {"pageInfo": {"hasNextPage": False}, "nodes": [
                {"__typename": "CheckRun", "name": "CI", "conclusion": "SUCCESS",
                 "status": "COMPLETED", "detailsUrl": "u",
                 "startedAt": "2026-01-01T00:00:00Z"}]}}}}]},
        "allCommits": {"nodes": [{"commit": {"oid": head,
                                             "signature": {"isValid": True}}}]},
    }}}}, open(sys.argv[1], "w"))
PY

for mode in text json; do
    args=(-R o/r 1)
    [ "$mode" = json ] && args+=(--json)
    rc=0
    out="$(PATH="$STUB_DIR:$PATH" bash "$SCRIPT" "${args[@]}" 2>"$STUB_DIR/err")" || rc=$?
    if grep -q 'Argument list too long' "$STUB_DIR/err"; then
        echo "  FAIL $mode: jq got the GraphQL answer through argv (Argument list too long)"
        fail=1
    elif [ "$mode" = json ] && ! jq -e '.next' <<<"$out" >/dev/null 2>&1; then
        echo "  FAIL $mode: no .next in the output (exit $rc)"
        sed 's/^/         /' "$STUB_DIR/err"
        fail=1
    elif [ "$mode" = text ] && ! grep -q '^NEXT: ' <<<"$out"; then
        echo "  FAIL $mode: no NEXT: line in the output (exit $rc)"
        sed 's/^/         /' "$STUB_DIR/err"
        fail=1
    else
        echo "  ok   $mode: a 300 KB GraphQL answer is read"
    fi
done

exit $fail
