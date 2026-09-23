#!/usr/bin/env bash
# Regression test: a private repository on a plan without branch rules is not
# an unreadable gate.
#
# There, `repos/<r>/rules/branches/<b>` (and the classic protection endpoint)
# answer HTTP 403 "Upgrade to GitHub Pro or make this repository public". No
# ruleset and no protection can exist on such a repository, so there is no
# required check to know about — but pr-status reported `rules-unavailable`
# and pr-merge.sh refused a green, CLEAN pull request
# (netresearch/claude-code-marketplace-P#8). Any other failure of that call
# must still mean "unknown".
#
# Runs pr-status.sh against a stubbed `gh`, so it needs no network and no repo.

set -euo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/skills/git-workflow/scripts/pr-status.sh"
STUB_DIR="$(mktemp -d)"
trap 'rm -rf "$STUB_DIR"' EXIT

export XDG_CACHE_HOME="$STUB_DIR/cache"

fail=0
check() { # check <name> <expected> <actual>
    if [ "$2" = "$3" ]; then
        echo "  ok   $1"
    else
        echo "  FAIL $1: expected '$2', got '$3'"
        fail=1
    fi
}

# stub [message printed by the REST calls; none = they answer an empty list]
stub() {
    local rest="echo '[]'; exit 0"
    [ -n "${1:-}" ] && rest="echo '$1' >&2; exit 1"
    cat > "$STUB_DIR/gh" <<STUB
#!/usr/bin/env bash
for arg in "\$@"; do
    case "\$arg" in
        repos/*) $rest ;;
    esac
done
cat <<'JSON'
{"data":{"repository":{"pullRequest":{
  "number":1,"title":"t","state":"OPEN","isDraft":false,"mergeable":"MERGEABLE",
  "mergeStateStatus":"CLEAN","reviewDecision":"","baseRefName":"main",
  "headRefName":"f","isCrossRepository":false,
  "author":{"login":"someone","__typename":"User"},
  "reviewRequests":{"nodes":[]},"reviewThreads":{"nodes":[]},
  "comments":{"nodes":[]},"latestReviews":{"nodes":[]},"reviews":{"nodes":[]},
  "commits":{"nodes":[{"commit":{"oid":"deadbeefdeadbeefdeadbeefdeadbeefdeadbeef",
    "signature":null,"statusCheckRollup":{"state":"SUCCESS","contexts":{"nodes":[]}}}}]}
}}}}
JSON
STUB
    chmod +x "$STUB_DIR/gh"
}

next_action() { PATH="$STUB_DIR:$PATH" bash "$SCRIPT" -R o/r 1 --json 2>/dev/null | jq -r '.next.action'; }

echo "case: plan without branch rules — same verdict as readable, empty rules"
stub
baseline=$(next_action)
check "baseline is a real verdict" "false" "$([ "$baseline" = "rules-unavailable" ] && echo true || echo false)"
stub 'gh: Upgrade to GitHub Pro or make this repository public to enable this feature. (HTTP 403)'
check "plan-limited matches the baseline" "$baseline" "$(next_action)"

echo "case: the message without HTTP 403 is not the plan limit"
stub 'gh: Upgrade to GitHub Pro or make this repository public to enable this feature. (HTTP 502)'
check "rules-unavailable" "rules-unavailable" "$(next_action)"

echo "case: any other failure still leaves the gate unknown"
stub 'gh: Resource not accessible by integration (HTTP 403)'
check "rules-unavailable" "rules-unavailable" "$(next_action)"

exit "$fail"
