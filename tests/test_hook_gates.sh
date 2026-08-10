#!/usr/bin/env bash
# tests/test_hook_gates.sh — the three shipped gates that had no test:
# merge-gate.sh, conflict-marker-gate.py and spec-cleanup-guard.sh.
#
# All three are hooks: they decide whether a command runs at all. A hook that
# fails open on a case it should block is invisible — nothing reports the
# permission it forgot to withhold — so the cases below are the blocking ones,
# plus the pass-through cases that must not become false positives.
#
# merge-gate is driven with a stubbed `gh`, so no network and no repo.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SCRIPTS="$ROOT/skills/git-workflow/scripts"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

fail=0
check() { # check <name> <expected> <actual>
    if [ "$2" = "$3" ]; then
        echo "  ok   $1"
    else
        echo "  FAIL $1: expected '$2', got '$3'"
        fail=1
    fi
}

# ---------------------------------------------------------------- merge-gate
echo "merge-gate.sh"

STUB_DIR="$WORK/stub"
mkdir -p "$STUB_DIR"
# Stub `gh`: the gate makes two different calls and they need different shapes
# — `gh pr view --json mergeStateStatus,url` first, then `gh api graphql` for
# the review threads. A single canned payload silently answers the first call
# with a null mergeStateStatus and an empty url, at which point the gate exits 0
# and every blocking case looks like a pass.
cat > "$STUB_DIR/gh" <<'STUB'
#!/usr/bin/env bash
for a in "$@"; do
    case "$a" in
        graphql) cat "$STUB_GRAPHQL"; exit 0 ;;
    esac
done
cat "$STUB_VIEW"
STUB
chmod +x "$STUB_DIR/gh"
export STUB_VIEW="$STUB_DIR/view.json" STUB_GRAPHQL="$STUB_DIR/graphql.json"

# gate <mergeStateStatus> <unresolved-threads> <command>  → prints the decision
gate() {
    printf '{"mergeStateStatus":"%s","url":"https://github.com/netresearch/git-workflow-skill/pull/163"}\n' "$1" > "$STUB_VIEW"
    local nodes=""
    [ "$2" -gt 0 ] && nodes='{"isResolved":false}'
    printf '{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[%s]}}}}}\n' "$nodes" > "$STUB_GRAPHQL"
    printf '{"tool_input":{"command":"%s"}}' "$3" \
        | PATH="$STUB_DIR:$PATH" bash "$SCRIPTS/merge-gate.sh" 2>&1
}

out=$(gate CLEAN 0 "gh pr merge 163 --repo netresearch/git-workflow-skill --merge")
check "a CLEAN pr with no threads is not denied" 0 "$(grep -ci 'deny' <<<"$out")"

out=$(gate BLOCKED 0 "gh pr merge 163 --repo netresearch/git-workflow-skill --merge")
check "a BLOCKED pr is denied" 1 "$(grep -ci 'deny' <<<"$out")"

out=$(gate UNSTABLE 0 "gh pr merge 163 --repo netresearch/git-workflow-skill --merge")
check "UNSTABLE is denied too — a red non-required check is still red" 1 "$(grep -ci 'deny' <<<"$out")"

out=$(gate CLEAN 1 "gh pr merge 163 --repo netresearch/git-workflow-skill --merge")
check "an unresolved thread is denied even when CLEAN" 1 "$(grep -ci 'deny' <<<"$out")"

out=$(gate CLEAN 0 "gh pr view 163 --repo netresearch/git-workflow-skill")
check "an unrelated gh command passes through" 0 "$(grep -ci 'deny' <<<"$out")"

# ------------------------------------------------------- conflict-marker-gate
echo "conflict-marker-gate.py"

repo="$WORK/cm"
mkdir -p "$repo"
git -C "$repo" init -q -b main
git -C "$repo" config user.name t; git -C "$repo" config user.email t@e.com
printf 'clean\n' > "$repo/ok.txt"; git -C "$repo" add ok.txt

marker_gate() { # marker_gate <cwd> <command>
    printf '{"tool_input":{"command":"%s"}}' "$2" \
        | ( cd "$1" && python3 "$SCRIPTS/conflict-marker-gate.py" 2>&1 )
}

out=$(marker_gate "$repo" "git commit -m 'chore: clean'")
check "a clean staged tree is not denied" 0 "$(grep -ci 'deny' <<<"$out")"

printf '<<<<<<< HEAD\nours\n=======\ntheirs\n>>>>>>> other\n' > "$repo/conflicted.txt"
git -C "$repo" add conflicted.txt
out=$(marker_gate "$repo" "git commit -m 'chore: with markers'")
check "staged conflict markers are denied" 1 "$(grep -ci 'deny' <<<"$out")"

out=$(marker_gate "$repo" "git status")
check "a non-commit command passes through" 0 "$(grep -ci 'deny' <<<"$out")"

# Fails open outside a repository — a hook that hard-errors would block every
# command in a non-repo directory.
out=$(marker_gate "$WORK" "git commit -m x")
check "outside a repository it fails open" 0 "$(grep -ci 'deny' <<<"$out")"

# ------------------------------------------------------- spec-cleanup-guard
echo "spec-cleanup-guard.sh"

repo="$WORK/spec"
mkdir -p "$repo"
git -C "$repo" init -q -b main
git -C "$repo" config user.name t; git -C "$repo" config user.email t@e.com
echo x > "$repo/README.md"; git -C "$repo" add README.md
git -C "$repo" commit -q -m "chore: seed"

( cd "$repo" && bash "$SCRIPTS/spec-cleanup-guard.sh" >/dev/null 2>&1 )
check "a clean repo exits 0" 0 "$?"

mkdir -p "$repo/docs/superpowers"
echo plan > "$repo/docs/superpowers/plan.md"
( cd "$repo" && bash "$SCRIPTS/spec-cleanup-guard.sh" >/dev/null 2>&1 )
check "an untracked planning artifact is reported" 1 "$?"

# The script's stated invariant: it never deletes, stages or modifies anything.
check "the artifact still exists after the run" yes \
    "$([ -f "$repo/docs/superpowers/plan.md" ] && echo yes || echo no)"
check "nothing was staged" "" "$(git -C "$repo" diff --cached --name-only)"

echo
if [ "$fail" -eq 0 ]; then
    echo "All hook-gate tests passed"
else
    echo "Some hook-gate tests FAILED"
fi
exit "$fail"
