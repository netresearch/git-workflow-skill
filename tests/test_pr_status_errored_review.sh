#!/usr/bin/env bash
# Regression test: a FAILED Copilot review must not count as a review.
#
# Copilot answers a failed review as an ordinary COMMENTED row ("Copilot
# encountered an error and was unable to review…", "…reached their quota
# limit"). Before the fix, pr-status.sh counted any Copilot review row on the
# head as a review and reported NEXT=merge for a PR nothing had read.
#
# Runs pr-status.sh against a stubbed `gh`, so it needs no network and no repo.

set -euo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/skills/git-workflow/scripts/pr-status.sh"
STUB_DIR="$(mktemp -d)"
trap 'rm -rf "$STUB_DIR"' EXIT

fail=0
check() { # check <name> <expected> <actual>
    if [ "$2" = "$3" ]; then
        echo "  ok   $1"
    else
        echo "  FAIL $1: expected '$2', got '$3'"
        fail=1
    fi
}

# Build a stub `gh` whose graphql reply carries one Copilot review with the
# given body, everything else clean and mergeable.
make_stub() { # make_stub <review-body>
    cat > "$STUB_DIR/gh" <<STUB
#!/usr/bin/env bash
# args: api graphql ... | api repos/<r>/rules/branches/<b>
for a in "\$@"; do
  case "\$a" in
    graphql) GQL=1 ;;
    repos/*/rules/branches/*) RULES=1 ;;
  esac
done
if [ -n "\${RULES:-}" ]; then
  echo '[{"type":"copilot_code_review","parameters":{}}]'
  exit 0
fi
cat <<'JSON'
{"data":{"repository":{
  "mergeCommitAllowed":true,"rebaseMergeAllowed":false,"squashMergeAllowed":false,
  "pullRequest":{
    "number":1,"title":"t","state":"OPEN","isDraft":false,
    "mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","reviewDecision":null,
    "author":{"login":"someone"},
    "baseRefName":"main","headRefName":"f","headRefOid":"deadbeefcafe","isCrossRepository":false,
    "reviews":{"nodes":[{"author":{"login":"copilot-pull-request-reviewer"},
                         "state":"COMMENTED","commit":{"oid":"deadbeefcafe"},
                         "body":"__BODY__"}]},
    "reviewRequests":{"nodes":[]},
    "reviewThreads":{"nodes":[]},
    "commits":{"nodes":[{"commit":{"oid":"deadbeefcafe",
      "statusCheckRollup":{"state":"SUCCESS","contexts":{"nodes":[
        {"__typename":"CheckRun","name":"CI","conclusion":"SUCCESS","status":"COMPLETED",
         "detailsUrl":"u","startedAt":"2026-01-01T00:00:00Z"}]}}}}]},
    "allCommits":{"nodes":[{"commit":{"oid":"deadbeefcafe","signature":{"isValid":true}}}]}
  }}}}
JSON
STUB
    # Substitute the body without letting quoting reach the heredoc above.
    python3 - "$STUB_DIR/gh" "$1" <<'PY'
import sys, json
p, body = sys.argv[1], sys.argv[2]
s = open(p).read().replace('__BODY__', json.dumps(body)[1:-1])
open(p, 'w').write(s)
PY
    chmod +x "$STUB_DIR/gh"
}

run_next() { PATH="$STUB_DIR:$PATH" bash "$SCRIPT" -R o/r 1 --json | jq -r '.next.action'; }
run_flag() { PATH="$STUB_DIR:$PATH" bash "$SCRIPT" -R o/r 1 --json | jq -r ".$1"; }

echo "case 1: Copilot errored (generic failure) — must NOT count as a review"
make_stub "Copilot encountered an error and was unable to review this pull request. You can try again by re-requesting a review."
check "copilot_review_errored"     "true"           "$(run_flag copilot_review_errored)"
check "has_copilot_review_on_head" "false"          "$(run_flag has_copilot_review_on_head)"
check "next.action"                "request-review" "$(run_next)"

echo "case 2: Copilot errored (quota exhausted) — same"
make_stub "Copilot was unable to review this pull request because the user who requested the review has reached their quota limit."
check "copilot_review_errored"     "true"           "$(run_flag copilot_review_errored)"
check "next.action"                "request-review" "$(run_next)"

echo "case 3: a real Copilot review — still counts, gate opens"
make_stub "Pull request review complete. Two suggestions below, neither blocking."
check "copilot_review_errored"     "false"          "$(run_flag copilot_review_errored)"
check "has_copilot_review_on_head" "true"           "$(run_flag has_copilot_review_on_head)"
check "next.action"                "merge"          "$(run_next)"

echo "case 4: a real review that merely mentions the phrase mid-sentence — counts"
make_stub "I was unable to review the generated fixtures, but the rest looks fine."
check "copilot_review_errored"     "false"          "$(run_flag copilot_review_errored)"
check "next.action"                "merge"          "$(run_next)"

if [ "$fail" -eq 0 ]; then
    echo "all pass"
else
    echo "FAILURES"
    exit 1
fi
