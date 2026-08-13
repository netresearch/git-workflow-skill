#!/usr/bin/env bash
# Regression test: the --json key list in pr-status.sh's header must match what
# --json actually emits.
#
# Why this is a test and not a comment: a caller who guesses a field name gets
# `null` from jq and no warning, so a watcher polling `.mergeStateStatus`
# (the GraphQL name, not this script's) never fires and reads as "still
# running" forever. The header exists to stop that guess — which only works
# while it is true, and a documented contract that nobody checks rots at the
# first new field.
#
# Runs pr-status.sh against a stubbed `gh`, so it needs no network and no repo.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/skills/git-workflow/scripts/pr-status.sh"
STUB_DIR="$(mktemp -d)"
trap 'rm -rf "$STUB_DIR"' EXIT

fail=0

# --- stub `gh`: one rules payload, one GraphQL payload -----------------------

printf '%s\n' '[{"type":"copilot_code_review","parameters":{}}]' > "$STUB_DIR/rules.json"

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
        "mergeable": "MERGEABLE", "mergeStateStatus": "CLEAN", "reviewDecision": None,
        "author": {"login": "someone"},
        "baseRefName": "main", "headRefName": "f", "headRefOid": head,
        "isCrossRepository": False,
        "reviews": {"nodes": []},
        "reviewRequests": {"nodes": []},
        "reviewThreads": {"nodes": []},
        "commits": {"nodes": [{"commit": {"oid": head, "statusCheckRollup": {
            "state": "SUCCESS", "contexts": {"nodes": [
                {"__typename": "CheckRun", "name": "CI", "conclusion": "SUCCESS",
                 "status": "COMPLETED", "detailsUrl": "u",
                 "startedAt": "2026-01-01T00:00:00Z"}]}}}}]},
        "allCommits": {"nodes": [{"commit": {"oid": head,
                                             "signature": {"isValid": True}}}]},
    }}}}, open(sys.argv[1], "w"))
PY

# --- the two lists -----------------------------------------------------------

emitted="$(PATH="$STUB_DIR:$PATH" bash "$SCRIPT" -R o/r 1 --json | jq -r 'keys[]' | sort)"

# The documented block: the indented run of key names between the "--json
# contract" heading and the first line that is not part of it. Matching on
# indentation rather than on a marker keeps the header readable as prose.
documented="$(
  awk '
    /^# --json contract$/ { inblock = 1; next }
    !inblock { next }
    /^#   [a-z]/ { sub(/^#   /, ""); print; next }
    /^# `checks` is/ { exit }
  ' "$SCRIPT" | tr " " "\n" | sed "/^$/d" | sort
)"

# --- compare both directions -------------------------------------------------

if [ -z "$emitted" ]; then
    echo "  FAIL the stubbed run emitted no JSON keys at all"
    exit 1
fi
if [ -z "$documented" ]; then
    echo "  FAIL no key list found under the '--json contract' header"
    exit 1
fi

undocumented="$(comm -23 <(printf '%s\n' "$emitted") <(printf '%s\n' "$documented"))"
stale="$(comm -13 <(printf '%s\n' "$emitted") <(printf '%s\n' "$documented"))"

if [ -n "$undocumented" ]; then
    echo "  FAIL --json emits keys the header does not list:"
    printf '         %s\n' "$undocumented"
    echo "       Add them to the '--json contract' block in pr-status.sh."
    fail=1
else
    echo "  ok   every emitted key is documented"
fi

if [ -n "$stale" ]; then
    echo "  FAIL the header lists keys --json does not emit:"
    printf '         %s\n' "$stale"
    echo "       Remove them from the '--json contract' block in pr-status.sh."
    fail=1
else
    echo "  ok   every documented key is emitted"
fi

# --help must show the block; a fixed line range used to truncate it.
if bash "$SCRIPT" --help | grep -q '^--json contract$'; then
    echo "  ok   --help shows the contract"
else
    echo "  FAIL --help does not show the '--json contract' block"
    fail=1
fi

exit $fail
