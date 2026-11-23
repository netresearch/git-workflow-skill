#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: Netresearch DTT GmbH
# Test: pr-status.sh --threads lists every unresolved review thread, readable.
#
# Reading open threads used to mean a hand-written GraphQL query and a body
# full of CodeRabbit scaffolding: HTML comments, nested <details> blocks with
# the agent prompt, <picture> icons. --threads prints the id, path:line,
# author, severity label and the finding text without that markup.
#
# Case one is a real CodeRabbit thread comment, copied verbatim from
# netresearch/git-workflow-skill#479 into
# tests/fixtures/coderabbit-thread/git-workflow-skill-479.json.
#
# Runs pr-status.sh against a stubbed `gh`, so it needs no network and no repo.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/skills/git-workflow/scripts/pr-status.sh"
FIXTURE="$ROOT/tests/fixtures/coderabbit-thread/git-workflow-skill-479.json"
STUB_DIR="$(mktemp -d)"
trap 'rm -rf "$STUB_DIR"' EXIT

export XDG_CACHE_HOME="$STUB_DIR/cache"

fail=0
check() { # check <name> <expected> <actual>
    if [ "$2" = "$3" ]; then
        echo "  ok   $1"
    else
        echo "  FAIL $1"
        diff <(printf '%s\n' "$2") <(printf '%s\n' "$3") | sed 's/^/       /' || true
        fail=1
    fi
}
contains() { # contains <name> <needle> <haystack>
    case "$3" in
        *"$2"*) echo "  ok   $1" ;;
        *) echo "  FAIL $1: '$2' not found in output"; fail=1 ;;
    esac
}
lacks() { # lacks <name> <needle> <haystack>
    case "$3" in
        *"$2"*) echo "  FAIL $1: '$2' should not appear"; fail=1 ;;
        *) echo "  ok   $1" ;;
    esac
}

# The stub answers the GraphQL thread query from page files: page-1.json for
# the first request, page-<cursor>.json for a request carrying that cursor. A
# missing page file is a failed call. STUB_MODE=fail fails every call.
cat > "$STUB_DIR/gh" <<STUB
#!/usr/bin/env bash
if [ "\${STUB_MODE:-}" = fail ]; then
  echo 'gh: HTTP 502: Bad Gateway' >&2
  exit 1
fi
page=1
for a in "\$@"; do
  case "\$a" in cursor=*) page="\${a#cursor=}" ;; esac
done
f="$STUB_DIR/page-\$page.json"
[ -f "\$f" ] || { echo "gh: no stubbed page \$page" >&2; exit 1; }
cat "\$f"
STUB
chmod +x "$STUB_DIR/gh"

# page <name> <hasNextPage> <endCursor> <totalCount> <threads-json>
page() {
    python3 - "$STUB_DIR/page-$1.json" "$2" "$3" "$4" "$5" <<'PY'
import json, sys
out, has_next, cursor, total, threads = sys.argv[1:6]
json.dump({"data": {"repository": {"pullRequest": {"reviewThreads": {
    "totalCount": int(total),
    "pageInfo": {"hasNextPage": has_next == "true",
                 "endCursor": cursor or None},
    "nodes": json.loads(threads)}}}}}, open(out, "w"))
PY
}

# thread <id> <resolved> <outdated> <path> <line> <originalLine> <author> <body>
thread() {
    python3 - "$@" <<'PY'
import json, sys
tid, resolved, outdated, path, line, orig, author, body = sys.argv[1:9]
num = lambda v: None if v == "" else int(v)
print(json.dumps({"id": tid, "isResolved": resolved == "true",
                  "isOutdated": outdated == "true", "path": path or None,
                  "line": num(line), "originalLine": num(orig),
                  "comments": {"nodes": [{"author": {"login": author}, "body": body}]}}))
PY
}

run() { PATH="$STUB_DIR:$PATH" bash "$SCRIPT" -R o/r 7 --threads; }
reset_pages() { rm -f "$STUB_DIR"/page-*.json; }

CR_BODY="$(jq -r .body "$FIXTURE")"

# Synthetic, built from the shapes the CodeRabbit fixtures under tests/fixtures
# show: the older italic label line, a <details open> block holding a nested
# <details>, a multi-line HTML comment, a <picture> with a <source>, and a run
# of blank lines.
# shellcheck disable=SC2016  # $x is text inside the comment body, not shell
NEST_BODY='<!-- coderabbit-ai-generated:v1 -->

_🛠️ Refactor suggestion_ | _🟡 Minor_

**Quote the variable.**

The unquoted expansion splits on spaces.
A second line of the same paragraph.



<details open>
<summary>📝 Committable suggestion</summary>

<details>
<summary>inner</summary>

```diff
-echo $x
+echo "$x"
```

</details>

</details>

<!--
multi-line
hidden note
-->
<picture><source media="(prefers-color-scheme: dark)" srcset="d.svg"><img src="l.svg" alt=""></picture> Trailing prose after a picture.'

HUMAN_BODY='Why is this a **major** change? The old name still works.'

echo "case 1: CodeRabbit markup is stripped, the label is printed, resolved threads are not"
reset_pages
page 1 false "" 4 "[
  $(thread T_CR false false skills/git-workflow/references/pull-request-workflow.md 198 196 coderabbitai "$CR_BODY"),
  $(thread T_NEST false false scripts/x.sh 12 12 coderabbitai "$NEST_BODY"),
  $(thread T_DONE true false scripts/y.sh 3 3 coderabbitai 'RESOLVED-MARKER should never be printed'),
  $(thread T_HUMAN false true src/a.php '' 7 linawolf "$HUMAN_BODY")
]"
rc=0; out=$(run 2>&1) || rc=$?
check "exits 0" "0" "$rc"
expected='3 unresolved thread(s) on o/r#7

thread T_CR
  at      : skills/git-workflow/references/pull-request-workflow.md:198
  author  : coderabbitai
  severity: Major
    **Major** · **Functional Correctness** · **Quick win**

    **Compare failure causes before assigning the fix.**

    If the same job fails on the base and PR for different reasons, this rule sends only the base failure to a separate PR and leaves the PR-specific failure unresolved. Compare the failed steps and logs, then rerun the PR after the base fix. Treat only a confirmed inherited failure as a prerequisite.

    ✅ Confirmed as addressed by @CybotTM

thread T_NEST
  at      : scripts/x.sh:12
  author  : coderabbitai
  severity: Minor
    _🛠️ Refactor suggestion_ | _🟡 Minor_

    **Quote the variable.**

    The unquoted expansion splits on spaces.
    A second line of the same paragraph.

    Trailing prose after a picture.

thread T_HUMAN (outdated)
  at      : src/a.php:7
  author  : linawolf
    Why is this a **major** change? The old name still works.'
check "whole listing" "$expected" "$out"
# shellcheck disable=SC2016  # literal text to look for
for markup in '<!--' '-->' '<details' '</details>' '<summary' '<picture' '<img' '<source' 'Prompt to fix issue' 'hidden note' 'echo "$x"'; do
    lacks "no '$markup' left" "$markup" "$out"
done
lacks "the resolved thread is not listed" "T_DONE" "$out"
lacks "nor its text" "RESOLVED-MARKER" "$out"

echo "case 2: zero unresolved threads"
reset_pages
page 1 false "" 1 "[$(thread T_DONE true false scripts/y.sh 3 3 coderabbitai 'done')]"
rc=0; out=$(run 2>&1) || rc=$?
check "exits 0" "0" "$rc"
check "says so in one line" "0 unresolved threads on o/r#7" "$out"

echo "case 3: threads on two pages are listed together"
reset_pages
page 1 true c1 2 "[$(thread T_P1 false false a.sh 1 1 alice 'first page')]"
page c1 false c2 2 "[$(thread T_P2 false false b.sh 2 2 bob 'second page')]"
rc=0; out=$(run 2>&1) || rc=$?
check    "exits 0" "0" "$rc"
contains "counts both pages" "2 unresolved thread(s) on o/r#7" "$out"
contains "page one is listed" "thread T_P1" "$out"
contains "page two is listed" "thread T_P2" "$out"

echo "case 4: a failing gh call exits non-zero and prints no count"
reset_pages
page 1 false "" 0 "[]"
rc=0; out=$(STUB_MODE=fail run 2>/dev/null) || rc=$?
err=$(STUB_MODE=fail run 2>&1 >/dev/null || true)
check    "exits 2" "2" "$rc"
lacks    "no '0 unresolved' after a failed call" "0 unresolved" "$out"
check    "stdout is empty" "" "$out"
contains "the gh error reaches stderr" "HTTP 502: Bad Gateway" "$err"
contains "and names the PR" "o/r#7" "$err"

echo "case 5: a failure on page two prints nothing from page one"
reset_pages
page 1 true c1 2 "[$(thread T_P1 false false a.sh 1 1 alice 'first page')]"
rc=0; out=$(run 2>/dev/null) || rc=$?
check "exits 2" "2" "$rc"
check "stdout is empty" "" "$out"

echo "case 6: a GraphQL errors body is a failure, not zero threads"
reset_pages
printf '%s\n' '{"data":{"repository":{"pullRequest":null}},"errors":[{"message":"Could not resolve to a PullRequest with the number of 7."}]}' > "$STUB_DIR/page-1.json"
rc=0; out=$(run 2>/dev/null) || rc=$?
err=$(run 2>&1 >/dev/null || true)
check    "exits 2" "2" "$rc"
check    "stdout is empty" "" "$out"
contains "the GraphQL message reaches stderr" "Could not resolve to a PullRequest" "$err"

echo "case 7: combinations it does not serve are refused"
rc=0; PATH="$STUB_DIR:$PATH" bash "$SCRIPT" -R o/r 7 --threads --watch >/dev/null 2>&1 || rc=$?
check "--threads --watch exits 2" "2" "$rc"
rc=0; PATH="$STUB_DIR:$PATH" bash "$SCRIPT" -R o/r 7 --threads --json >/dev/null 2>&1 || rc=$?
check "--threads --json exits 2" "2" "$rc"
rc=0; PATH="$STUB_DIR:$PATH" bash "$SCRIPT" -R gitlab.example.com/g/p 7 --threads >/dev/null 2>&1 || rc=$?
check "--threads on a GitLab project exits 2" "2" "$rc"

echo "case 8: control characters in a comment, an author login and a path are removed"
reset_pages
ESC_BODY=$'**Title**\n\e[2J\e]0;pwned\aVisible text\u009b31m stays.\tTabbed.'
page 1 false "" 1 "[$(thread T_ESC false false $'src/\e[31mx.sh' 4 4 $'ev\e[31mil' "$ESC_BODY")]"
rc=0; out=$(run 2>&1) || rc=$?
check    "exits 0" "0" "$rc"
lacks    "no ESC byte" $'\e' "$out"
lacks    "no BEL byte" $'\a' "$out"
lacks    "no C1 CSI (U+009B)" $'\u009b' "$out"
contains "the login is kept without the escape" "author  : ev[31mil" "$out"
contains "the path is kept without the escape" "at      : src/[31mx.sh:4" "$out"
contains "the prose is kept" "Visible text31m stays."$'\t'"Tabbed." "$out"

echo "case 9: details, picture and img tags are removed whatever their case"
reset_pages
UC_BODY=$'**Title**\n\n<DETAILS><SUMMARY>Prompt</SUMMARY>HIDDEN-UPPER</DETAILS>\n<details>HIDDEN-SPACE</details >\n<Picture><IMG src="x.svg"></Picture >Kept prose.'
page 1 false "" 1 "[$(thread T_UC false false a.sh 1 1 coderabbitai "$UC_BODY")]"
rc=0; out=$(run 2>&1) || rc=$?
check    "exits 0" "0" "$rc"
lacks    "no upper-case details text" "HIDDEN-UPPER" "$out"
lacks    "a closing tag with a space still closes" "HIDDEN-SPACE" "$out"
lacks    "no DETAILS tag" "<DETAILS" "$out"
lacks    "no IMG tag" "<IMG" "$out"
contains "the prose is kept" "Kept prose." "$out"

echo "case 10: a single-asterisk severity label is recognised"
reset_pages
page 1 false "" 2 "[$(thread T_STAR false false a.sh 1 1 coderabbitai $'*Major* · Functional Correctness\n\n**Title**'),$(thread T_PROSE false false b.sh 2 2 alice 'Is this *major* at all?')]"
rc=0; out=$(run 2>&1) || rc=$?
check    "exits 0" "0" "$rc"
contains "the label is printed" "severity: Major" "$out"
check    "lower-case prose gets no label" "1" "$(grep -c '^  severity:' <<<"$out")"

[ "$fail" = "0" ] && echo "All cases passed." || echo "FAILURES"
exit "$fail"
