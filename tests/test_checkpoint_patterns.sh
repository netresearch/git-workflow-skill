#!/usr/bin/env bash
# tests/test_checkpoint_patterns.sh — every `type: command` checkpoint must be
# executable by the assessment runner.
#
# The runner (automated-assessment run-checkpoints.sh) refuses a pattern that
# chains commands, and reads YAML line by line so a block scalar arrives as the
# literal `|-`. Neither produces a visible failure: the checkpoint is simply
# skipped, and the assessment report says nothing about it. GW-15 and GW-16 sat
# in this file rejected for as long as they existed, and GW-17 was written the
# same way on the day it was added.
#
# The rule is mirrored here rather than imported: automated-assessment is not a
# dependency of this repo, and a test that needs an absent checkout is a test
# that does not run.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECKPOINTS="$(cd "$HERE/.." && pwd)/skills/git-workflow/checkpoints.yaml"

fail=0
report() { echo "  FAIL $1"; fail=1; }

# Mirrored from is_safe_eval_command's allowed_cmds.
ALLOWED="grep egrep fgrep find test wc jq yq python3 python composer php \
phpstan phpcs phpcbf rector phpunit node npm cat head tail ls stat file diff \
sort uniq git make go sed awk tr cut xargs for if while case until [ set \
printf echo true false gh"

echo "checkpoints.yaml: command patterns"

# id<TAB>pattern for every mechanical entry whose type is command
while IFS=$'\t' read -r id pat; do
    [ -n "$id" ] || continue

    case "$pat" in
        "|"|"|-"|">"|">-"|"")
            report "$id: pattern is a multi-line YAML scalar — the runner receives '${pat:-<empty>}'"
            continue
            ;;
    esac

    if grep -qE '[;`]|&&|\|\||\$\(' <<<"$pat"; then
        report "$id: pattern contains a command-chaining metacharacter (; && || \` \$()) — the runner rejects it"
        continue
    fi
    if grep -qF '..' <<<"$pat"; then
        report "$id: pattern contains '..' — the runner rejects it as path traversal"
        continue
    fi

    # The runner strips a leading `!` before looking at the base command, so a
    # negated pipeline is judged on the command that follows it.
    stripped="${pat#!}"
    read -r base _ <<<"$stripped"
    if [[ " $ALLOWED " != *" $base "* ]]; then
        report "$id: base command '$base' is not on the runner's allowlist"
        continue
    fi

    echo "  ok   $id: '$base …' is executable by the runner"
done < <(awk '
    /^mechanical:/  { sect = 1; next }
    /^[a-z_]+:/     { sect = 0 }
    !sect           { next }
    /^  - id:/ { if (id != "" && type == "command") print id "\t" pat; id = $3; type = ""; pat = ""; next }
    /^    type:/    { type = $2 }
    /^    pattern:/ {
        line = $0
        sub(/^    pattern:[[:space:]]*/, "", line)
        if (line ~ /^".*"$/)        { sub(/^"/, "", line); sub(/"$/, "", line) }
        else if (line ~ /^\x27.*\x27$/) { sub(/^\x27/, "", line); sub(/\x27$/, "", line) }
        pat = line
    }
    END { if (id != "" && type == "command") print id "\t" pat }
' "$CHECKPOINTS")

echo
if [ "$fail" -eq 0 ]; then
    echo "All command patterns are runnable"
else
    echo "Some command patterns would never run"
fi
exit "$fail"
