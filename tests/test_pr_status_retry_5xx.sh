#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: Netresearch DTT GmbH
# A GraphQL read GitHub answers with a 5xx is repeated up to two times; any
# other failure is reported after one call. Nine single-shot reads of one
# session failed on "gh: HTTP 502" and worked when repeated by hand.
#
# Runs against a stubbed `gh` that counts its GraphQL calls; no network.

set -euo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/skills/git-workflow/scripts/pr-status.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export XDG_CACHE_HOME="$WORK/cache" PR_STATUS_5XX_WAIT=0

fail=0
cat > "$WORK/gh" <<STUB
#!/usr/bin/env bash
for a in "\$@"; do
  case "\$a" in repos/*) echo '[]'; exit 0 ;; esac
done
n=\$(( \$(cat "$WORK/calls") + 1 ))
echo "\$n" > "$WORK/calls"
if [ "\$n" -le "\$FAILURES" ]; then echo "\$MESSAGE" >&2; exit 1; fi
cat <<'JSON'
{"data":{"repository":{"pullRequest":{
  "number":1,"title":"t","state":"OPEN","isDraft":false,"mergeable":"MERGEABLE",
  "mergeStateStatus":"CLEAN","reviewDecision":"","baseRefName":"main",
  "headRefName":"f","isCrossRepository":false,
  "author":{"login":"someone","__typename":"User"},
  "reviewRequests":{"nodes":[]},"reviewThreads":{"nodes":[]},
  "comments":{"nodes":[]},"latestReviews":{"nodes":[]},"reviews":{"nodes":[]},
  "commits":{"nodes":[{"commit":{"oid":"deadbeefdeadbeefdeadbeefdeadbeefdeadbeef",
    "signature":null,"statusCheckRollup":{"state":"SUCCESS","contexts":{"pageInfo":{"hasNextPage":false},"nodes":[]}}}}]}
}}}}
JSON
STUB
chmod +x "$WORK/gh"

# check <name> <failures> <message> <want: ok|failed> <want graphql calls>
check() {
  local name="$1" failures="$2" message="$3" want="$4" want_calls="$5" got=ok calls
  echo 0 > "$WORK/calls"
  FAILURES="$failures" MESSAGE="$message" PATH="$WORK:$PATH" bash "$SCRIPT" -R o/r 1 --json >"$WORK/out" 2>"$WORK/err" || got=failed
  calls="$(cat "$WORK/calls")"
  if [[ "$got" == "$want" && "$calls" == "$want_calls" ]]; then
    echo "  ok   $name"
  else
    echo "  FAIL $name: $got after $calls calls (want $want after $want_calls)"
    fail=1
  fi
}

check "two 502 answers, then a reading"      2 'gh: HTTP 502' ok 3
check "a persistent 502 fails after three"   9 'gh: HTTP 502' failed 3
grep -q 'HTTP 502' "$WORK/err" || { echo "  FAIL the cause is not on stderr"; fail=1; }
check "a rate limit is not repeated"         9 'gh: API rate limit already exceeded for user ID 1' failed 1
check "a login error is not repeated"        9 'gh: Bad credentials (HTTP 401)' failed 1

exit "$fail"
