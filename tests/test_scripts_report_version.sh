#!/usr/bin/env bash
# Regression test: every script answers --version, and answers for ITSELF.
#
# #209 measured two installations on one machine declaring the same version
# while shipping different scripts, so `--self-reviewed` existed in one and not
# the other. Nothing could be asked "which copy am I running" — a missing flag
# read as a missing feature, and roughly a dozen PRs were merged by hand.
#
# A release fixes one instance of that. --version makes the next one visible.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS="$ROOT/skills/git-workflow/scripts"
SKILL="$ROOT/skills/git-workflow/SKILL.md"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail=0
check() {
    if [ "$2" = "$3" ]; then
        echo "  ok   $1"
    else
        echo "  FAIL $1: expected '$2', got '$3'"
        fail=1
    fi
}

# Read straight from the frontmatter, independently of the awk the scripts use
# — a test that reuses the implementation cannot catch the implementation being
# wrong. python3 is already a dependency of this repository (conflict-marker-gate.py).
declared() {
    python3 - "$1" <<'PY'
import re, sys
for line in open(sys.argv[1], encoding="utf-8"):
    m = re.match(r'\s*version:\s*"?([^"\n]+?)"?\s*$', line)
    if m:
        print(m.group(1))
        break
PY
}

VERSION="$(declared "$SKILL")"
echo "SKILL.md declares: $VERSION"
if [ -z "$VERSION" ]; then
    echo "  FAIL could not read a version from $SKILL"
    exit 1
fi

echo "case 1: every script answers --version with that number"
for s in "$SCRIPTS"/*.sh; do
    name="$(basename "$s")"
    out="$(bash "$s" --version 2>&1 || true)"
    check "$name reports the version" "$name $VERSION" "$(printf '%s\n' "$out" | head -1)"
done

echo "case 2: every script names the file that answered"
for s in "$SCRIPTS"/*.sh; do
    name="$(basename "$s")"
    out="$(bash "$s" --version 2>&1 || true)"
    check "$name names its own path" "path: $SCRIPTS/$name" "$(printf '%s\n' "$out" | sed -n 2p)"
done

# The property the whole flag exists for. A second copy on the same machine must
# report ITS OWN number — reading the version from a checkout elsewhere, or from
# a git tag, would reproduce exactly the confusion #209 documented.
echo "case 3: a second copy reports its own SKILL.md, not this one"
COPY="$TMP/other/skills/git-workflow"
mkdir -p "$COPY"
cp -r "$SCRIPTS" "$COPY/scripts"
printf -- '---\nname: git-workflow\nversion: "0.0.1-other"\n---\n\n# other\n' > "$COPY/SKILL.md"
for name in pr-status.sh pr-merge.sh verify-git-workflow.sh; do
    out="$(bash "$COPY/scripts/$name" --version 2>&1 || true)"
    check "$name reports the copy version"  "$name 0.0.1-other"          "$(printf '%s\n' "$out" | head -1)"
    check "$name reports the copy path"     "path: $COPY/scripts/$name"  "$(printf '%s\n' "$out" | sed -n 2p)"
done

# A copy whose SKILL.md was not shipped must still answer. Refusing here would
# make the flag useless in exactly the broken installation it exists to identify.
echo "case 4: no SKILL.md beside the script — answers 'unknown', does not fail"
BARE="$TMP/bare/skills/git-workflow"
mkdir -p "$BARE"
cp -r "$SCRIPTS" "$BARE/scripts"
out="$(bash "$BARE/scripts/pr-status.sh" --version 2>&1)"; rc=$?
check "exit status is 0"        "0"                     "$rc"
check "version reads unknown"   "pr-status.sh unknown"  "$(printf '%s\n' "$out" | head -1)"

# --version must not need the network, a git repository, or a PR. It is the one
# question that has to be answerable when everything else is broken.
echo "case 5: answers outside a git repository, with no gh on PATH"
NOGIT="$TMP/nogit"
mkdir -p "$NOGIT"
if ( cd "$NOGIT" && PATH="/usr/bin:/bin" bash "$SCRIPTS/pr-status.sh" --version >/dev/null 2>&1 ); then
    echo "  ok   answers with a stripped PATH outside a repository"
else
    echo "  FAIL --version needs a repository or gh on PATH"
    fail=1
fi

echo "case 6: the number matches .claude-plugin/plugin.json"
PLUGIN="$ROOT/.claude-plugin/plugin.json"
if [ -f "$PLUGIN" ]; then
    check "plugin.json agrees" "$VERSION" "$(jq -r '.version' "$PLUGIN")"
else
    echo "  skip no .claude-plugin/plugin.json"
fi

if [ "$fail" -eq 0 ]; then
    echo "all pass"
else
    echo "FAILURES"
    exit 1
fi
