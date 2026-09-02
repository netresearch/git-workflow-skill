#!/usr/bin/env bash
# tests/test_checkpoint_patterns.sh — every `type: command` checkpoint must be
# executable by the assessment runner.
#
# The runner (automated-assessment run-checkpoints.sh) applies ONE OF TWO
# rules, chosen by the pattern's shape, and a pattern that fails its rule is
# refused without a visible failure: the checkpoint is simply skipped, and the
# assessment report says nothing about it. GW-15 and GW-16 sat in this file
# rejected for as long as they existed, and GW-17 was written the same way on
# the day it was added.
#
#   single line -> is_safe_eval_command: a base-command whitelist, no `..`,
#                  and no chaining metacharacter (; && || ` $()).
#   block scalar -> is_safe_script_text: the runner collects the body and runs
#                  it from a temp file, so the whitelist and the operator ban
#                  do NOT apply — control syntax, assignments and $() are what
#                  a script IS. Only the $IFS splice check and the
#                  dangerous-pattern regex survive.
#
# The second branch is why this file once reported a block scalar as "the
# runner receives '|-'": that was true of an older runner, and stopped being
# true when it grew block-scalar collection. Both rules are mirrored here
# rather than imported: automated-assessment is not a dependency of this repo,
# and a test that needs an absent checkout is a test that does not run.

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

# Body of a block-scalar `pattern:` for one checkpoint id, de-indented the way
# the runner de-indents it (first body line sets the indent).
block_body() {
    awk -v want="$1" '
        /^  - id:/ { id = $3; inblock = 0; next }
        id != want { next }
        /^    (pattern|command|target):[[:space:]]*\|[-+]?[[:space:]]*$/ { inblock = 1; next }
        inblock && /^      / { sub(/^      /, ""); print; next }
        inblock && /^[[:space:]]*$/ { print ""; next }
        inblock { inblock = 0 }
    ' "$CHECKPOINTS"
}

echo "checkpoints.yaml: command patterns"

# id<TAB>pattern for every mechanical entry whose type is command
while IFS=$'\t' read -r id pat; do
    [ -n "$id" ] || continue

    case "$pat" in
        "")
            report "$id: pattern is empty — the runner has no command to run"
            continue
            ;;
        "|"|"|-"|"|+")
            # Block scalar: judged by the is_safe_script_text mirror.
            body="$(block_body "$id")"
            if [ -z "${body//[[:space:]]/}" ]; then
                report "$id: block-scalar pattern has an empty body"
                continue
            fi
            # $IFS splicing, ignored inside single quotes (bash does not
            # expand there, so a pattern INSPECTING for the trick is fine).
            # shellcheck disable=SC2001  # regex span removal; ${var//x/y} cannot express [^']*
            outside_sq="$(sed "s/'[^']*'//g" <<<"$body")"
            if grep -qE '\$\{?IFS' <<<"$outside_sq"; then
                report "$id: block body splices words with \$IFS — the runner rejects it"
                continue
            fi
            if grep -qE '(curl[[:space:]].*\|[[:space:]]*(ba)?sh|wget[[:space:]].*\|[[:space:]]*(ba)?sh|eval[[:space:]]|exec[[:space:]]|rm[[:space:]]+-r|sudo[[:space:]]|mkfs|dd[[:space:]]+if=|chmod[[:space:]]+-R|chown[[:space:]]+-R)' <<<"$body"; then
                report "$id: block body contains a dangerous pattern — the runner rejects it"
                continue
            fi
            echo "  ok   $id: block body passes the runner's script screening"
            continue
            ;;
        ">"|">-"|">+")
            # A folded scalar joins its lines with spaces, which turns a
            # multi-command body into one unrunnable line. The runner only
            # collects `|`.
            report "$id: pattern is a FOLDED scalar ('$pat') — use a literal block '|'"
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
