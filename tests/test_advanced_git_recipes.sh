#!/usr/bin/env bash
# Executable form of the three recipes in references/advanced-git.md:
#   - "A long rebase needs a reference merge to resolve against"
#   - "A merge resolved in favour of the branch silently reverts upstream work"
#   - "Verify a branch split by blob identity, not by reading the diffs"
#
# Three review rounds found the same defect class each time: a recipe that was
# reasoned about at the edited line and never run end to end, from the cwd and
# in the shell the document prescribes. Reading a diff cannot catch a missing
# `git add`, a `-C` that only resolves from another directory, or a `rev-parse`
# that echoes its argument instead of failing. Running it can.
#
# Keep this in step with the document: if a recipe changes there, change it here
# and let the suite say whether it still works.

set -uo pipefail

failures=0
pass() { printf '  OK   %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1"; failures=$((failures + 1)); }
check() { # check <label> <expected> <actual>
  if [ "$2" = "$3" ]; then pass "$1"; else
    fail "$1"; printf '       expected: %s\n       actual:   %s\n' "$2" "$3"
  fi
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export GIT_CONFIG_GLOBAL="$TMP/gitconfig" GIT_CONFIG_SYSTEM=/dev/null
git config --global user.email t@example.com
git config --global user.name  Test
git config --global commit.gpgsign false
git config --global init.defaultBranch main
# The recipes must survive a global that signs tags: a lightweight tag dies
# under it, which is why the reference merge is pinned with a branch.
git config --global tag.gpgsign true

# --------------------------------------------------------------------------
printf '\n== reference-merge recipe (bare layout, real conflict)\n'
# --------------------------------------------------------------------------
proj="$TMP/p1"; mkdir -p "$proj"; cd "$proj" || exit 1
git init -q --bare .bare
git clone -q .bare seed
(
  cd seed || exit 1
  printf 'l1\nl2\nl3\n' > f.txt
  git add -A && git commit -qm base && git push -q origin main
  git checkout -q -b feature
  printf 'l1\nBRANCH\nl3\n' > f.txt && git commit -qam branch && git push -q origin feature
  git checkout -q main
  printf 'l1\nMAIN\nl3\n' > f.txt && git commit -qam main-side && git push -q origin main
)
git -C .bare worktree add -q ../wt feature          # the branch worktree
git -C .bare worktree add -q --detach "$TMP/ref" feature

git -C "$TMP/ref" merge --no-commit --no-ff origin/main >/dev/null 2>&1
printf 'l1\nRESOLVED\nl3\n' > "$TMP/ref"/f.txt
printf 'leftover\n' > "$TMP/ref"/f.txt.orig        # what mergetool leaves behind

out=$(git -C "$TMP/ref" commit -m REF 2>&1); rc=$?
if [ "$rc" -ne 0 ]; then pass "commit before staging refuses (rc=$rc)"; else fail "commit before staging succeeded"; fi
# Wording depends on whether the ref worktree is detached: an attached one says
# "Committing is not possible because you have unmerged files", a detached one
# reports "Not currently on any branch" first. Either way it refuses.
case "$out" in
  *"unmerged files"* | *"not currently on any branch"* | *"Not currently on any branch"*)
    pass "and says why ($(printf '%s' "$out" | head -1))" ;;
  *) fail "unexpected message: $out" ;;
esac

git -C "$TMP/ref" add -- f.txt
dirty=$(git -C "$TMP/ref" status --porcelain | grep -c '^??')
check "status --porcelain still shows the untracked leftover" "1" "$dirty"

git -C "$TMP/ref" commit -qm REF && pass "commit after staging by name"
git -C "$TMP/ref" branch ref-target && pass "branch pins REF under tag.gpgsign=true"

# The untracked leftover must NOT be in REF — that is why we stage by name.
in_ref=$(git -C "$TMP/ref" ls-tree --name-only ref-target | grep -c 'f.txt.orig' || true)
check "leftover kept out of REF" "0" "$in_ref"

# Step 2/3 from the branch worktree.
( cd "$proj/wt" && git checkout ref-target -- f.txt ) && pass "checkout from a branch ref"
got=$(tr '\n' ' ' < "$proj/wt/f.txt")
check "resolution landed in the branch worktree" "l1 RESOLVED l3 " "$got"

# Step 4, from the project root: needs -C and --force, and two statements.
cd "$proj" || exit 1
git -C wt worktree remove --force "$TMP/ref" 2>/dev/null && pass "worktree remove --force"
git -C wt branch -D ref-target >/dev/null 2>&1 && pass "pin deleted"
if [ -d "$TMP/ref" ]; then fail "ref worktree still present"; else pass "ref worktree gone"; fi

# --------------------------------------------------------------------------
printf '\n== dropped-upstream-work check (two merges, one sibling, later churn)\n'
# --------------------------------------------------------------------------
r="$TMP/p2"; mkdir -p "$r"; cd "$r" || exit 1; git init -q .
echo base > a.txt; echo base > b.txt; git add -A; git commit -qm base
git branch -q feature; git branch -q sibling
echo up1 > a.txt; git commit -qam up1; u1=$(git rev-parse HEAD)
git checkout -q sibling; echo s > s.txt; git add s.txt; git commit -qm sibling-work
git checkout -q feature; echo w > w.txt; git add w.txt; git commit -qm branch-work
git merge -q -s ours "$u1" -m "Merge branch 'main' into feature"      # drops a.txt
git checkout -q main; echo up2 > b.txt; git commit -qam up2; u2=$(git rev-parse HEAD)
git checkout -q feature
git merge -q -s ours "$u2" -m "Merge branch 'main' into feature"      # drops b.txt
git merge -q --no-ff sibling -m "Merge branch 'sibling' into feature" # not upstream
git checkout -q main; echo more >> a.txt; git commit -qam later-churn  # post-merge churn
git checkout -q feature

report=$(
  merges=$(git rev-list --merges main..feature)
  for m in $merges; do
    git merge-base --is-ancestor "$m^2" main || { echo "SKIP"; continue; }
    BASE=$(git merge-base "$m^1" "$m^2")
    git diff -z --name-only "$BASE" "$m^2" | while IFS= read -r -d '' f; do
      git diff --quiet main feature -- "$f" || echo "DIFFERS: $f"
    done
  done | sort | tr '\n' ' '
)
check "both drops found, sibling merge skipped" "DIFFERS: a.txt DIFFERS: b.txt SKIP " "$report"

empty_range=$(git rev-list --merges feature..feature | wc -l)
check "range is empty once the branch has landed (the all-clear trap)" "0" "$empty_range"

# Reconstruction uses the merge's own sides, so post-merge churn is not reported.
m=$(git rev-list --merges main..feature | tail -1)
BASE=$(git merge-base "$m^1" "$m^2")
git show "$BASE:a.txt" > "$TMP/base"; git show "$m^1:a.txt" > "$TMP/ours"
git show "$m^2:a.txt" > "$TMP/theirs"; git show "$m:a.txt" > "$TMP/result"
git merge-file -p --diff3 "$TMP/ours" "$TMP/base" "$TMP/theirs" > "$TMP/merged" 2>/dev/null
churn=$(diff -u "$TMP/result" "$TMP/merged" | grep -c '^+more' || true)
check "post-merge churn not reported as dropped work" "0" "$churn"
drop=$(diff -u "$TMP/result" "$TMP/merged" | grep -c '^+up1' || true)
check "the genuine drop is reported" "1" "$drop"

# --------------------------------------------------------------------------
printf '\n== split verification (deletions, spaces, bad branch name)\n'
# --------------------------------------------------------------------------
s="$TMP/p3"; mkdir -p "$s"; cd "$s" || exit 1; git init -q .
echo k > keep.txt; echo d > doomed.txt; echo g > gone.txt; echo x > "sp ace.txt"
git add -A; git commit -qm base; git branch -q split1
git checkout -q -b umbrella
git rm -q doomed.txt gone.txt; echo k2 > keep.txt; echo x2 > "sp ace.txt"
git commit -qam "umbrella: delete two, change two"
git checkout -q split1
git rm -q doomed.txt; echo k2 > keep.txt; echo x2 > "sp ace.txt"
git commit -qam "split1: carries all but the gone.txt deletion"
git checkout -q umbrella

run_split() { # run_split <branches…>
  local branches="$*"
  for b in $branches; do
    git rev-parse --verify -q "$b^{commit}" >/dev/null || { echo "no such branch: $b"; return 1; }
  done
  git diff -z --name-only main umbrella | while IFS= read -r -d '' f; do
    u=$(git rev-parse --verify -q "umbrella:$f") || u=ABSENT
    carried=""
    for b in $branches; do
      v=$(git rev-parse --verify -q "$b:$f") || v=ABSENT
      [ "$v" = "$u" ] && carried=$b && break
    done
    [ -n "$carried" ] || echo "NOT CARRIED: $f"
  done | sort | tr '\n' ' '
}

check "reports only the uncarried deletion; spaces intact" \
      "NOT CARRIED: gone.txt " "$(run_split split1)"

out=$(run_split split1 typo-branch 2>&1); rc=$?
check "an unresolvable branch name aborts instead of masking a miss" "1" "$rc"
check "and says which name" "no such branch: typo-branch" "$out"

printf '\n---- failures: %s\n' "$failures"
[ "$failures" -eq 0 ]
