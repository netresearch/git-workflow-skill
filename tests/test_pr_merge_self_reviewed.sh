#!/usr/bin/env bash
# --self-reviewed (#203): pr-merge may clear exactly one refusal — a
# request-review whose refusing branch stamped reason=bot-review-unsatisfiable
# — by posting the on-the-record `Self-review: <head-sha>` attestation as the
# PR author and asking again. Everything else must stay as strict as without
# the flag, and a dry run must never perform the gate-opening write.
#
# Runs against a stubbed pr-status.sh (sequenced: first call answers
# status.1.json, later calls status.2.json) and a stubbed `gh`, so it needs no
# network and no repo.

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

HEAD_OID="deadbeefcafe0000"

# status fixture builder. Args: <file> <action> <reason|-> <have_marker>
# The top-level quota fields are set TRUE on purpose in every fixture: the
# flag must key on next.reason alone, and a fixture where the global state
# and the branch reason disagree is exactly the false-attestation trap.
make_status_json() {
    local why="clean" reason_line=""
    [ "$2" = "merge" ] || why="no review on the current head — do not merge unreviewed"
    [ "$3" = "-" ] || reason_line="\"reason\": \"$3\","
    cat > "$STUB_DIR/$1" <<JSON
{
  "repo": "o/r", "number": 559, "queue_active": false,
  "merge_methods": ["merge", "rebase"],
  "headOid": "$HEAD_OID", "author": "the-author",
  "copilot_quota_exhausted": true, "copilot_error_count": 2,
  "self_review_on_head": $4,
  "next": {"action": "$2", $reason_line "why": "$why", "method": "--merge"}
}
JSON
}

# Sequenced pr-status stub: first invocation serves status.1.json, every later
# one status.2.json (falling back to 1 when 2 is absent).
make_status_stub() {
    cat > "$STUB_DIR/pr-status.sh" <<STATUS
#!/usr/bin/env bash
echo x >> "$STUB_DIR/status.calls"
n=\$(wc -l < "$STUB_DIR/status.calls")
if [ "\$n" -gt 1 ] && [ -f "$STUB_DIR/status.2.json" ]; then
  cat "$STUB_DIR/status.2.json"
else
  cat "$STUB_DIR/status.1.json"
fi
STATUS
    chmod +x "$STUB_DIR/pr-status.sh"
    : > "$STUB_DIR/status.calls"
}

# gh stub: logs every call, answers `api user` with the viewer file, records
# the body of `pr comment`, lets `pr merge` succeed, and answers the outcome
# poll with MERGED.
make_gh() {
    cat > "$STUB_DIR/gh" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$1 \$2" >> "$STUB_DIR/calls.log"
if [ "\$1 \$2" = "api user" ]; then
  cat "$STUB_DIR/viewer.json"; exit 0
fi
if [ "\$1 \$2" = "pr comment" ]; then
  # Find --body and persist it for assertions.
  while [ \$# -gt 0 ]; do
    if [ "\$1" = "--body" ]; then printf '%s' "\$2" > "$STUB_DIR/comment.body"; fi
    shift
  done
  exit 0
fi
if [ "\$1 \$2" = "pr merge" ]; then
  echo "Merging pull request #559"; exit 0
fi
if [ "\$1 \$2" = "api graphql" ]; then
  echo '{"data":{"repository":{"pullRequest":{"state":"MERGED","isInMergeQueue":false,"autoMergeRequest":null}}}}'
  exit 0
fi
exit 0
STUB
    chmod +x "$STUB_DIR/gh"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB_DIR/sleep"
    chmod +x "$STUB_DIR/sleep"
    : > "$STUB_DIR/calls.log"
    rm -f "$STUB_DIR/comment.body"
}

# `gh api user --jq .login` — the stub ignores --jq and prints the file, so
# the file holds the raw login only.
set_viewer_raw() { printf '%s\n' "$1" > "$STUB_DIR/viewer.json"; }

run() { PATH="$STUB_DIR:$PATH" bash "$SCRIPT" -R o/r 559 "$@" 2>"$STUB_DIR/err"; }

echo "case 1: unsatisfiable refusal + --self-reviewed — posts the attestation, then merges"
make_status_stub; make_gh; set_viewer_raw "the-author"
make_status_json status.1.json request-review bot-review-unsatisfiable false
make_status_json status.2.json merge          -                        true
out=$(run --self-reviewed); rc=$?
err=$(cat "$STUB_DIR/err")
check "exit code" "0" "$rc"
says  "merged"                 "559 merged (--merge)" "$out"
says  "announced the posting"  "posted Self-review attestation for deadbeefcafe" "$err"
if grep -q '^pr comment$' "$STUB_DIR/calls.log"; then
    echo "  ok   a comment was posted"
else
    echo "  FAIL no comment was posted"; fail=1
fi
body=$(cat "$STUB_DIR/comment.body" 2>/dev/null || echo "")
says "comment carries the marker line" "Self-review: $HEAD_OID" "$body"

echo "case 2: request-review WITHOUT the unsatisfiable reason — refused, no false attestation"
# Global quota fields are true in the fixture (see make_status_json): a flag
# keyed on them instead of next.reason would post a factually false
# attestation onto e.g. a classic require_last_push_approval refusal.
make_status_stub; make_gh; set_viewer_raw "the-author"
make_status_json status.1.json request-review - false
out=$(run --self-reviewed); rc=$?
err=$(cat "$STUB_DIR/err")
check "exit code" "2" "$rc"
says  "names the refusal" "a live review path exists" "$err"
if grep -q '^pr comment$' "$STUB_DIR/calls.log"; then
    echo "  FAIL a comment was posted despite the refusal"; fail=1
else
    echo "  ok   no comment was posted"
fi

echo "case 3: --self-reviewed refused for a non-author caller"
make_status_stub; make_gh; set_viewer_raw "somebody-else"
make_status_json status.1.json request-review bot-review-unsatisfiable false
out=$(run --self-reviewed); rc=$?
err=$(cat "$STUB_DIR/err")
check "exit code" "2" "$rc"
says  "names both logins" "the-author" "$err"
says  "names the viewer"  "somebody-else" "$err"
if grep -q '^pr comment$' "$STUB_DIR/calls.log"; then
    echo "  FAIL a comment was posted by a non-author"; fail=1
else
    echo "  ok   no comment was posted"
fi

echo "case 4: attestation already on the head — no second comment, merges"
make_status_stub; make_gh; set_viewer_raw "the-author"
make_status_json status.1.json request-review bot-review-unsatisfiable true
make_status_json status.2.json merge          -                        true
out=$(run --self-reviewed); rc=$?
check "exit code" "0" "$rc"
if grep -q '^pr comment$' "$STUB_DIR/calls.log"; then
    echo "  FAIL posted a duplicate attestation"; fail=1
else
    echo "  ok   the existing attestation was reused"
fi

echo "case 5: WITHOUT the flag the refusal is unchanged (exit 1)"
make_status_stub; make_gh; set_viewer_raw "the-author"
make_status_json status.1.json request-review bot-review-unsatisfiable false
out=$(run); rc=$?
err=$(cat "$STUB_DIR/err")
check "exit code" "1" "$rc"
says  "plain refusal" "not merging o/r#559 — request-review" "$err"
says_not "no attestation posting" "posted Self-review attestation" "$err"

echo "case 6: --dry-run --self-reviewed — the gate-opening write is previewed, never posted"
make_status_stub; make_gh; set_viewer_raw "the-author"
make_status_json status.1.json request-review bot-review-unsatisfiable false
make_status_json status.2.json merge          -                        true
out=$(run --self-reviewed --dry-run); rc=$?
check "exit code" "0" "$rc"
says  "previews the posting" "dry-run — would post the Self-review attestation" "$out"
if grep -q '^pr comment$' "$STUB_DIR/calls.log"; then
    echo "  FAIL dry-run posted the attestation comment"; fail=1
else
    echo "  ok   dry-run performed no write"
fi
if grep -q '^pr merge$' "$STUB_DIR/calls.log"; then
    echo "  FAIL dry-run ran the merge"; fail=1
else
    echo "  ok   dry-run ran no merge"
fi

echo "case 7: attestation posted but the second read still refuses — exit 1, no merge"
make_status_stub; make_gh; set_viewer_raw "the-author"
make_status_json status.1.json request-review bot-review-unsatisfiable false
make_status_json status.2.json request-review bot-review-unsatisfiable true
out=$(run --self-reviewed); rc=$?
err=$(cat "$STUB_DIR/err")
check "exit code" "1" "$rc"
says  "refusal after re-read" "not merging o/r#559 — request-review" "$err"
if grep -q '^pr merge$' "$STUB_DIR/calls.log"; then
    echo "  FAIL merged although the re-read refused"; fail=1
else
    echo "  ok   no merge on a refusing re-read"
fi

if [ "$fail" -eq 0 ]; then
    echo "all pass"
else
    echo "FAILURES"
    exit 1
fi
