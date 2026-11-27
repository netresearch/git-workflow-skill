#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: Netresearch DTT GmbH
# pr-merge.sh --wait --request-coderabbit: a head CodeRabbit refused as rate
# limited is requested again once, after the reset its notice names.
#
# CodeRabbit allows about one review per hour per account and does not resume
# a refused head by itself. Without the flag, the gate answers request-review
# and pr-merge.sh --wait returns at once; the operator slept until the reset,
# posted the comment by hand and armed the wait again (2026-11-27). With the
# flag the call sleeps to the reset plus a margin, posts one
# "@coderabbitai review" for the head, keeps waiting while that review runs,
# and merges when the gate opens.
#
# Runs pr-merge.sh against a stubbed gh, a stubbed pr-status.sh and a sleep
# that really sleeps only for short waits (the reset is set a few seconds
# ahead), so it needs no network and finishes in seconds.

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

# pr-status.sh stub: the n-th --json call answers status.<n>.json if it
# exists, else status.json.
cat > "$STUB_DIR/pr-status.sh" <<STATUS
#!/usr/bin/env bash
case " \$* " in
  *" --json "*) ;;
  *) echo "NEXT: stub"; exit 0 ;;
esac
echo x >> "$STUB_DIR/json.log"
n=\$(wc -l < "$STUB_DIR/json.log" | tr -d ' ')
if [ -f "$STUB_DIR/status.\$n.json" ]; then cat "$STUB_DIR/status.\$n.json"; exit 0; fi
cat "$STUB_DIR/status.json"
STATUS
chmod +x "$STUB_DIR/pr-status.sh"

# gh stub: every call is logged. The comment read applies the --jq filter
# pr-merge.sh passes to comments.json, a REST page of issue comments, or fails
# with comments.fail; pr comment logs its arguments and fails with
# comment.fail.
cat > "$STUB_DIR/gh" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$1 \$2" >> "$STUB_DIR/calls.log"
case "\$1 \$2" in
  "pr merge") echo "Merging pull request #745"; exit 0 ;;
  "pr list") exit 0 ;;
  "pr comment")
    printf '%s\n' "\$*" >> "$STUB_DIR/posts.log"
    wc -l < "$STUB_DIR/json.log" | tr -d ' ' >> "$STUB_DIR/posted_at.log"
    [ -f "$STUB_DIR/comment.fail" ] && { echo "HTTP 403: Resource not accessible" >&2; exit 1; }
    exit 0 ;;
  "api repos/o/r/issues/745/comments?per_page=100")
    [ -f "$STUB_DIR/comments.fail" ] && { echo "HTTP 502: Bad Gateway" >&2; exit 1; }
    filter=""; prev=""
    for a in "\$@"; do [ "\$prev" = "--jq" ] && filter="\$a"; prev="\$a"; done
    jq -c "\$filter" "$STUB_DIR/comments.json"; exit 0 ;;
  "api graphql") cat "$STUB_DIR/graphql.json"; exit 0 ;;
esac
echo "gh stub: unexpected call \$*" >&2
exit 1
STUB
chmod +x "$STUB_DIR/gh"

# Waits up to 5 s are real, so the time the reset names can pass; longer
# ones (the --interval waits) are only logged.
cat > "$STUB_DIR/sleep" <<SLEEP
#!/usr/bin/env bash
printf '%s\n' "\$1" >> "$STUB_DIR/sleep.log"
[ "\$1" -le 5 ] && /bin/sleep "\$1"
exit 0
SLEEP
chmod +x "$STUB_DIR/sleep"

reset() {
    rm -f "$STUB_DIR"/status*.json "$STUB_DIR"/*.fail "$STUB_DIR/json.log" \
          "$STUB_DIR/sleep.log" "$STUB_DIR/posts.log" "$STUB_DIR/posted_at.log" "$STUB_DIR/comments.json"
    : > "$STUB_DIR/calls.log"
    printf '%s\n' '{"data":{"repository":{"pullRequest":{"state":"MERGED","isInMergeQueue":false,"autoMergeRequest":null}}}}' \
      > "$STUB_DIR/graphql.json"
}

HEAD=499b3ea8deadbeef0000000000000000000000ff
HEAD_AT=2026-11-27T10:00:00Z
REFUSED_AT=2026-11-27T11:00:00Z
CRWHY="no review on the current head (499b3ea8) — do not merge unreviewed — CodeRabbit refused THIS head as rate limited"

# st <file> <action> <coderabbit_on_head> <retry_at|null> [draft] [has_review_on_head]
#    [checks_settled] [failing-json]
st() {
    cat > "$STUB_DIR/$1" <<JSON
{
  "repo": "o/r", "number": 745, "state": "OPEN", "draft": ${5:-false},
  "queue_active": false, "queue_entry": null,
  "merge_methods": ["merge", "rebase"], "cross_repository": false,
  "author": "me", "headOid": "$HEAD", "head": "feature/x", "base": "main",
  "has_review_on_head": ${6:-false},
  "checks_settled": ${7:-true}, "checks": {"failing": ${8:-[]}},
  "coderabbit_on_head": "$3", "coderabbit_retry_at": $4,
  "body_freshness": {"edited_at": "$HEAD_AT", "edited": false, "head_committed_at": "$HEAD_AT", "older_than_head": false},
  "next": {"action": "$2", "why": "$CRWHY", "method": "--merge"}
}
JSON
}
# The comments the REST read returns, as GitHub sends them: CodeRabbit's
# summary naming the head, last edited at the refusal, and an operator's
# request from before the refusal. comment <login> <type> <created> <updated> <body>
# appends one more.
comments() {
    cat > "$STUB_DIR/comments.json" <<JSON
[
 {"user":{"login":"coderabbitai[bot]","type":"Bot"},"created_at":"2026-11-27T10:01:00Z","updated_at":"$REFUSED_AT","body":"Review rate limited ... $HEAD ... Next included review available in 48 minutes."},
 {"user":{"login":"me","type":"User"},"created_at":"2026-11-27T10:30:00Z","updated_at":"2026-11-27T10:30:00Z","body":"@coderabbitai review"}
]
JSON
}
comment() {
    jq --arg u "$1" --arg t "$2" --arg c "$3" --arg e "$4" --arg b "$5" \
      '. + [{user: {login: $u, type: $t}, created_at: $c, updated_at: $e, body: $b}]' \
      "$STUB_DIR/comments.json" > "$STUB_DIR/comments.tmp" && mv "$STUB_DIR/comments.tmp" "$STUB_DIR/comments.json"
}

run() { PATH="$STUB_DIR:$PATH" PR_MERGE_CODERABBIT_MARGIN=1 bash "$SCRIPT" -R o/r 745 "$@" 2>"$STUB_DIR/err"; }
posts() { if [ -f "$STUB_DIR/posts.log" ]; then wc -l < "$STUB_DIR/posts.log" | tr -d ' '; else echo 0; fi; }
merges() { grep -c '^pr merge$' "$STUB_DIR/calls.log"; }
sleeps() { if [ -f "$STUB_DIR/sleep.log" ]; then tr '\n' ' ' < "$STUB_DIR/sleep.log" | sed 's/ $//'; fi; }
# A reset two seconds from now, as CodeRabbit's notice would name it.
soon() { date -u -d "@$(( $(date +%s) + 2 ))" +%Y-%m-%dT%H:%M:%SZ; }

echo "case 1: rate-limited head + flag — waits for the reset, posts once, waits for the review, merges"
reset; comments
RETRY=$(soon)
st status.1.json request-review rate-limited "\"$RETRY\""
st status.2.json request-review rate-limited "\"$RETRY\""
st status.3.json request-review in-progress null
st status.json merge clean null false true
t0=$(date +%s)
out=$(run --wait --request-coderabbit); rc=$?
t1=$(date +%s)
err=$(cat "$STUB_DIR/err")
check "exit code" "0" "$rc"
says  "reports merged" "745 merged (--merge)" "$out"
check "one request posted" "1" "$(posts)"
says  "the request is @coderabbitai review on the PR" "pr comment 745 --repo o/r --body @coderabbitai review" "$(cat "$STUB_DIR/posts.log" 2>/dev/null)"
says  "names the reset it waits for" "sleeping until $RETRY plus 1s" "$err"
says  "says it posted" "posted @coderabbitai review for 499b3ea8dead on o/r#745" "$err"
check "not posted before the reset plus margin" "true" "$([ $((t1 - t0)) -ge 2 ] && echo true || echo false)"
check "merged once" "1" "$(merges)"
case "$(sleeps)" in
    [1-3]" 20 20") echo "  ok   one sleep to the reset, then the --interval waits" ;;
    *) echo "  FAIL sleeps: expected '<1-3> 20 20', got '$(sleeps)'"; fail=1 ;;
esac

echo "case 2: a request newer than the head commit and the refusal exists — no second post"
reset; comments
comment me User 2026-11-27T11:30:00Z 2026-11-27T11:30:00Z "@coderabbitai review"
st status.1.json request-review rate-limited '"2026-11-27T11:48:00Z"'
st status.2.json request-review in-progress null
st status.json merge clean null false true
out=$(run --wait --request-coderabbit); rc=$?
err=$(cat "$STUB_DIR/err")
check "exit code" "0" "$rc"
check "nothing posted" "0" "$(posts)"
says  "says why" "already carries an @coderabbitai review request newer than 499b3ea8dead" "$err"
check "merged once" "1" "$(merges)"

echo "case 2b: no comment names the head; a request older than the head commit does not count"
reset
printf '%s\n' '[]' > "$STUB_DIR/comments.json"
comment coderabbitai[bot] Bot 2026-11-27T08:00:00Z 2026-11-27T08:00:00Z "Review rate limited ... an older head"
comment me User 2026-11-27T09:30:00Z 2026-11-27T09:30:00Z "@coderabbitai review"
st status.1.json request-review rate-limited '"2026-11-27T11:48:00Z"'
st status.2.json request-review in-progress null
st status.json merge clean null false true
out=$(run --wait --request-coderabbit); rc=$?
check "exit code" "0" "$rc"
check "one request posted" "1" "$(posts)"

echo "case 3: without the flag — unchanged: exit 1 at once, nothing posted or read"
reset; comments
st status.json request-review rate-limited '"2026-11-27T11:48:00Z"'
out=$(run --wait); rc=$?
err=$(cat "$STUB_DIR/err")
check "exit code" "1" "$rc"
says  "names the step as before" "not merging o/r#745 — request-review: $CRWHY" "$err"
check "no gh call at all" "" "$(tr '\n' ' ' < "$STUB_DIR/calls.log")"
check "no sleep" "" "$(sleeps)"
out=$(run --request-coderabbit); rc=$?
check "the flag without --wait is refused" "2" "$rc"
says  "with a reason" "--request-coderabbit only applies with --wait" "$(cat "$STUB_DIR/err")"

echo "case 4: a draft — nothing posted, the draft is reported"
reset; comments
st status.json request-review rate-limited '"2026-11-27T11:48:00Z"' true
out=$(run --wait --request-coderabbit); rc=$?
err=$(cat "$STUB_DIR/err")
check "exit code" "1" "$rc"
check "nothing posted" "0" "$(posts)"
says  "says CodeRabbit does not review drafts" "is a draft, and CodeRabbit does not review drafts — no @coderabbitai review posted" "$err"
check "no sleep" "" "$(sleeps)"
reset; comments
st status.json ready rate-limited '"2026-11-27T11:48:00Z"' true
out=$(run --wait --request-coderabbit); rc=$?
check "the ladder's own draft answer: exit 1" "1" "$rc"
check "nothing posted there either" "0" "$(posts)"
says  "reported there too" "is a draft, and CodeRabbit does not review drafts" "$(cat "$STUB_DIR/err")"

echo "case 5: checks still running — no request until they settle"
reset; comments
st status.1.json request-review rate-limited '"2026-11-27T11:48:00Z"' false false false
st status.2.json request-review rate-limited '"2026-11-27T11:48:00Z"' false false false
st status.3.json request-review rate-limited '"2026-11-27T11:48:00Z"'
st status.4.json request-review in-progress null
st status.json merge clean null false true
out=$(run --wait --request-coderabbit); rc=$?
check "exit code" "0" "$rc"
check "one request posted" "1" "$(posts)"
check "posted after the third gate read, the first with settled checks" "3" "$(cat "$STUB_DIR/posted_at.log" 2>/dev/null)"
check "read every --interval while the checks ran" "20 20 20 20" "$(sleeps)"

echo "case 6: a red check — no request, exit 1"
reset; comments
st status.json request-review rate-limited '"2026-11-27T11:48:00Z"' false false true '["build"]'
out=$(run --wait --request-coderabbit); rc=$?
check "exit code" "1" "$rc"
check "nothing posted" "0" "$(posts)"

echo "case 7: --dry-run — nothing waited for or posted"
reset; comments
st status.json request-review rate-limited '"2026-11-27T11:48:00Z"'
out=$(run --wait --dry-run --request-coderabbit); rc=$?
check "exit code" "1" "$rc"
check "nothing posted" "0" "$(posts)"
check "no sleep" "" "$(sleeps)"

echo "case 8: the post fails — exit 2, tried once"
reset; comments; touch "$STUB_DIR/comment.fail"
st status.json request-review rate-limited '"2026-11-27T11:48:00Z"'
out=$(run --wait --request-coderabbit); rc=$?
check "exit code" "2" "$rc"
check "one attempt" "1" "$(posts)"
says  "says it failed and is not retried" "posting @coderabbitai review on o/r#745 failed (not retried): HTTP 403" "$(cat "$STUB_DIR/err")"
check "nothing merged" "0" "$(merges)"

echo "case 9: the comment read fails — exit 2, nothing posted"
reset; touch "$STUB_DIR/comments.fail"
st status.json request-review rate-limited '"2026-11-27T11:48:00Z"'
out=$(run --wait --request-coderabbit); rc=$?
check "exit code" "2" "$rc"
check "nothing posted" "0" "$(posts)"
says  "says the read failed" "could not read the comments of o/r#745" "$(cat "$STUB_DIR/err")"

if [ "$fail" -eq 0 ]; then
    echo "all pass"
else
    echo "FAILURES"
    exit 1
fi
