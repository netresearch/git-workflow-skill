#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: Netresearch DTT GmbH
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

# A committed file that shows a conflict as a documentation example keeps
# its markers; changing another line of it must still commit.
repo="$WORK/cm-doc"
mkdir -p "$repo"
git -C "$repo" init -q -b main
git -C "$repo" config user.name t; git -C "$repo" config user.email t@e.com
printf 'intro\n<<<<<<< HEAD\nours\n=======\ntheirs\n>>>>>>> other\n' > "$repo/guide.md"
git -C "$repo" add guide.md
git -C "$repo" commit -q -m "docs: seed example"
printf 'intro, edited\n<<<<<<< HEAD\nours\n=======\ntheirs\n>>>>>>> other\n' > "$repo/guide.md"
git -C "$repo" add guide.md
out=$(marker_gate "$repo" "git commit -m 'docs: edit intro'")
check "markers already on HEAD are not denied" 0 "$(grep -ci 'deny' <<<"$out")"

printf '>>>>>>> stray\n' >> "$repo/guide.md"
git -C "$repo" add guide.md
out=$(marker_gate "$repo" "git commit -m 'docs: add stray marker'")
check "a marker added to a file with an example is denied" 1 "$(grep -ci 'deny' <<<"$out")"

# A file whose committed content is not valid UTF-8 still gets its staged
# markers counted; a decoding error must not end the gate without a verdict.
repo="$WORK/cm-bin"
mkdir -p "$repo"
git -C "$repo" init -q -b main
git -C "$repo" config user.name t; git -C "$repo" config user.email t@e.com
printf '\377\n' > "$repo/data.txt"
git -C "$repo" add data.txt
git -C "$repo" commit -q -m "chore: seed binary"
printf '<<<<<<< HEAD\nours\n=======\ntheirs\n>>>>>>> other\n' > "$repo/data.txt"
git -C "$repo" add data.txt
out=$(marker_gate "$repo" "git commit -m 'chore: markers over binary'")
check "markers replacing non-UTF-8 content are denied" 1 "$(grep -ci 'deny' <<<"$out")"

printf '\377\376 binary\n' > "$repo/data.txt"
git -C "$repo" add data.txt
out=$(marker_gate "$repo" "git commit -m 'chore: binary without markers'")
check "non-UTF-8 content without markers passes without a traceback" 0 "$(grep -ci 'deny\|traceback' <<<"$out")"

# A staged file with a non-ASCII name is checked too; git quotes such names
# in --name-only output unless -z is used.
repo="$WORK/cm-name"
mkdir -p "$repo"
git -C "$repo" init -q -b main
git -C "$repo" config user.name t; git -C "$repo" config user.email t@e.com
printf '<<<<<<< HEAD\nours\n=======\ntheirs\n>>>>>>> other\n' > "$repo/$(printf 'r\303\244tsel.md')"
git -C "$repo" add -A
out=$(marker_gate "$repo" "git commit -m 'docs: markers in a non-ASCII file name'")
check "markers in a file with a non-ASCII name are denied" 1 "$(grep -ci 'deny' <<<"$out")"

# `git -C <dir> commit` is checked in <dir>, not in the hook's current
# directory: markers staged elsewhere must be denied, and markers staged in the
# current directory must not deny a commit to another repository.
other="$WORK/cm-other"
mkdir -p "$other"
git -C "$other" init -q -b main
git -C "$other" config user.name t; git -C "$other" config user.email t@e.com
printf 'clean\n' > "$other/ok.txt"; git -C "$other" add ok.txt
out=$(marker_gate "$other" "git -C $repo commit -m 'docs: from elsewhere'")
check "git -C <repo with markers> commit from a clean repo is denied" 1 "$(grep -ci 'deny' <<<"$out")"
out=$(marker_gate "$repo" "git -C $other commit -m 'chore: clean elsewhere'")
check "git -C <clean repo> commit from a repo with markers passes" 0 "$(grep -ci 'deny' <<<"$out")"
out=$(marker_gate "$WORK" "git -C cm-name commit -m 'docs: relative -C'")
check "a relative -C resolves against the current directory" 1 "$(grep -ci 'deny' <<<"$out")"
out=$(marker_gate "$other" "git -C $WORK -C cm-name commit -m 'docs: chained -C'")
check "successive -C options combine as git combines them" 1 "$(grep -ci 'deny' <<<"$out")"
out=$(marker_gate "$other" "git --git-dir=$repo/.git --work-tree=$repo commit -m 'docs: git-dir'")
check "--git-dir=<repo>/.git with --work-tree is checked in that repository" 1 "$(grep -ci 'deny' <<<"$out")"
out=$(marker_gate "$other" "git --git-dir $repo/.git commit -m 'docs: git-dir separate value'")
check "--git-dir <repo>/.git as a separate argument is checked there" 1 "$(grep -ci 'deny' <<<"$out")"
out=$(marker_gate "$other" "git status && git -C $repo commit -m 'docs: second segment'")
check "a commit in a later segment of the line is checked in its own -C" 1 "$(grep -ci 'deny' <<<"$out")"

# The -C directory comes from a command the user has not approved yet. Its
# repository config must not run code while the gate reads the index: a
# core.fsmonitor command would otherwise execute before the approval prompt.
evil="$WORK/cm-evil"
mkdir -p "$evil"
git -C "$evil" init -q -b main
printf '<<<<<<< HEAD\nx\n>>>>>>> o\n' > "$evil/f.txt"; git -C "$evil" add f.txt
printf '#!/bin/sh\ntouch "%s/fsmonitor-ran"\n' "$WORK" > "$WORK/fsmon.sh"; chmod +x "$WORK/fsmon.sh"
git -C "$evil" config core.fsmonitor "$WORK/fsmon.sh"
out=$(marker_gate "$other" "git -C $evil commit -m x")
check "the -C repository's core.fsmonitor does not run" 0 "$([ -e "$WORK/fsmonitor-ran" ] && echo 1 || echo 0)"
check "its staged markers are still denied" 1 "$(grep -ci 'deny' <<<"$out")"

# A partial clone fetches a missing blob from its promisor remote when it is
# read, and the remote's uploadpack setting names the program that runs.
lazy="$WORK/cm-lazy"
git init -q -b main "$lazy"
git -C "$lazy" config core.repositoryformatversion 1
git -C "$lazy" config extensions.partialClone origin
git -C "$lazy" config remote.origin.url "file://$WORK/nowhere"
git -C "$lazy" config remote.origin.promisor true
printf '#!/bin/sh\ntouch "%s/uploadpack-ran"\nexit 1\n' "$WORK" > "$WORK/up.sh"; chmod +x "$WORK/up.sh"
git -C "$lazy" config remote.origin.uploadpack "$WORK/up.sh"
git -C "$lazy" config protocol.file.allow always
git -C "$lazy" update-index --add --cacheinfo 100644,1111111111111111111111111111111111111111,f.txt
marker_gate "$other" "git -C $lazy commit -m x" >/dev/null
check "a partial clone's missing blob does not start a fetch, protocol.file.allow=always or not" 0 "$([ -e "$WORK/uploadpack-ran" ] && echo 1 || echo 0)"

# A tilde: bash expands `-C ~/x` but leaves `--git-dir=~/x` alone, and the
# gate reads the path git receives.
out=$(HOME="$WORK" marker_gate "$other" "git -C ~/cm-name commit -m 'docs: tilde'")
check "-C ~/<repo> is read in \$HOME/<repo>" 1 "$(grep -ci 'deny' <<<"$out")"
out=$(HOME="$WORK" marker_gate "$other" "git --git-dir=~/cm-name/.git --work-tree=~/cm-name commit -m 'docs: tilde in ='")
check "--git-dir=~/<repo> is not expanded, as in bash" 0 "$(grep -ci 'deny' <<<"$out")"

# Every git call the gate makes carries the hardening. GIT_NO_LAZY_FETCH alone
# stops a lazy fetch on git 2.45+, so the partial-clone case above cannot show
# that GIT_ALLOW_PROTOCOL is set; a git wrapper on PATH records each call.
wrap="$WORK/gitwrap"; mkdir -p "$wrap"
real_git=$(command -v git)
# shellcheck disable=SC2016  # the $-expressions belong to the wrapper, not this shell
printf '#!/bin/sh\nprintf "allow=[%%s] set=%%s lazy=%%s args=%%s\\n" "$GIT_ALLOW_PROTOCOL" "${GIT_ALLOW_PROTOCOL+yes}" "$GIT_NO_LAZY_FETCH" "$*" >> "%s/git-calls"\nexec "%s" "$@"\n' "$WORK" "$real_git" > "$wrap/git"
chmod +x "$wrap/git"
: > "$WORK/git-calls"
printf '{"tool_input":{"command":"%s"}}' "git -C $repo commit -m x" \
    | ( cd "$other" && PATH="$wrap:$PATH" python3 "$SCRIPTS/conflict-marker-gate.py" >/dev/null 2>&1 )
calls=$(wc -l < "$WORK/git-calls")
check "the gate made git calls through the wrapper" 1 "$([ "$calls" -gt 0 ] && echo 1 || echo 0)"
check "every call sets an empty GIT_ALLOW_PROTOCOL" "$calls" "$(grep -c 'allow=\[\] set=yes' "$WORK/git-calls")"
check "every call sets GIT_NO_LAZY_FETCH" "$calls" "$(grep -c 'lazy=1' "$WORK/git-calls")"
check "every call refuses transports and fsmonitor" "$calls" "$(grep -c 'core.fsmonitor=false -c protocol.allow=never' "$WORK/git-calls")"

# diff.relative=true makes a diff run in a subdirectory list only the files
# below it; a commit made with -C <subdir> still includes the rest.
rel="$WORK/cm-rel"
git init -q -b main "$rel"; mkdir -p "$rel/sub"
git -C "$rel" config diff.relative true
printf '<<<<<<< HEAD\nx\n>>>>>>> o\n' > "$rel/top.txt"; git -C "$rel" add top.txt
out=$(marker_gate "$other" "git -C $rel/sub commit -m x")
check "-C <subdir> with diff.relative still sees markers above it" 1 "$(grep -ci 'deny' <<<"$out")"

# A committed example whose HEAD blob cannot be read (missing from a partial
# clone) is unknown, not zero markers: an edit that keeps the example passes.
miss="$WORK/cm-miss"
git init -q -b main "$miss"
git -C "$miss" config user.name t; git -C "$miss" config user.email t@e.com
printf 'intro\n<<<<<<< HEAD\nours\n=======\ntheirs\n>>>>>>> other\n' > "$miss/guide.md"
git -C "$miss" add guide.md; git -C "$miss" commit -q -m "docs: seed example"
oid=$(git -C "$miss" rev-parse HEAD:guide.md)
rm -f "$miss/.git/objects/${oid:0:2}/${oid:2}"
printf 'intro, edited\n<<<<<<< HEAD\nours\n=======\ntheirs\n>>>>>>> other\n' > "$miss/guide.md"
git -C "$miss" add guide.md
out=$(marker_gate "$other" "git -C $miss commit -m 'docs: edit intro'")
check "an unreadable HEAD blob is not counted as zero markers" 0 "$(grep -ci 'deny' <<<"$out")"

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
