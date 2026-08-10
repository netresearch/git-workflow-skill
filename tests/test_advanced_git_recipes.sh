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
ran=0
pass() { ran=$((ran + 1)); printf '  OK   %s\n' "$1"; }
fail() { ran=$((ran + 1)); printf '  FAIL %s\n' "$1"; failures=$((failures + 1)); }
check() { # check <label> <expected> <actual>
  if [ "$2" = "$3" ]; then pass "$1"; else
    fail "$1"; printf '       expected: %s\n       actual:   %s\n' "$2" "$3"
  fi
}
# `cmd && pass X` silently runs neither pass nor fail when cmd fails, so a
# broken step disappears instead of failing. Always go through this.
try() { # try <label> <cmd...>
  if "${@:2}" >/dev/null 2>&1; then pass "$1"; else fail "$1 (command failed)"; fi
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
# A resolution that both edits a tracked file AND creates one. The created path
# is what separates the three staging forms: -A sweeps the .orig too, -u skips
# helper.txt silently, staging by name gets exactly both.
printf 'l1\nRESOLVED\nl3\n' > "$TMP/ref"/f.txt
printf 'extracted\n'       > "$TMP/ref"/helper.txt
printf 'leftover\n'        > "$TMP/ref"/f.txt.orig   # what mergetool leaves behind

# A lightweight tag is the alternative the recipe rejects; prove why. The exit
# code varies by git version (1 and 128 both observed) — assert the refusal.
git -C "$TMP/ref" tag lightweight-probe HEAD >/dev/null 2>&1; tagrc=$?
if [ "$tagrc" -ne 0 ]; then pass "lightweight tag refused under tag.gpgsign=true (rc=$tagrc)"
else fail "lightweight tag was accepted under tag.gpgsign=true"; fi

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

git -C "$TMP/ref" add -- f.txt helper.txt
dirty=$(git -C "$TMP/ref" status --porcelain | grep -c '^??')
check "status --porcelain still shows the untracked leftover" "1" "$dirty"

try "commit after staging by name" git -C "$TMP/ref" commit -qm REF
try "branch pins REF" git -C "$TMP/ref" branch ref-target

tree=$(git -C "$TMP/ref" ls-tree -r --name-only ref-target | sort | tr '\n' ' ')
# helper.txt catches `add -u` (which skips paths the resolution creates);
# f.txt.orig catches `add -A` (which sweeps untracked files in).
check "REF holds exactly the resolution" "f.txt helper.txt " "$tree"

# Step 2/3 from the branch worktree.
try "checkout from a branch ref" git -C "$proj/wt" checkout ref-target -- f.txt helper.txt
got=$(tr '\n' ' ' < "$proj/wt/f.txt")
check "resolution landed in the branch worktree" "l1 RESOLVED l3 " "$got"

# Step 3 itself: with the branch worktree now holding REF's content for the
# conflicted paths, the assertion the recipe calls "the point" must be empty.
git -C "$proj/wt" add -- f.txt helper.txt >/dev/null 2>&1
git -C "$proj/wt" commit -qm "take REF" >/dev/null 2>&1
step3=$(git -C "$proj/wt" diff --stat ref-target HEAD)
check "step 3 prints nothing when the trees match" "" "$step3"

# And it must NOT be empty when they diverge — otherwise the assertion is not
# an assertion.
printf 'drift\n' >> "$proj/wt/f.txt"
git -C "$proj/wt" add -- f.txt >/dev/null 2>&1
git -C "$proj/wt" commit -qm drift >/dev/null 2>&1
drift=$(git -C "$proj/wt" diff --stat ref-target HEAD | wc -l)
if [ "$drift" -gt 0 ]; then pass "step 3 reports divergence"; else fail "step 3 stayed empty on a divergent tree"; fi

# Step 4, from the project root: needs -C and --force, and two statements.
cd "$proj" || exit 1
try "worktree remove --force" git -C wt worktree remove --force "$TMP/ref"
try "pin deleted" git -C wt branch -D ref-target
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

# This block is the recipe from advanced-git.md, verbatim apart from the
# placeholders. If the document changes, change it here and see what breaks.
report=$(
  merges=$(git rev-list --merges main..feature)
  for m in $merges; do
    [ "$(git rev-list --parents -n1 "$m" | wc -w)" -gt 3 ] && echo "OCTOPUS"
    if git merge-base --is-ancestor "$m^2" main; then up=$m^2; base_side=$m^1
    elif git merge-base --is-ancestor "$m^1" main; then up=$m^1; base_side=$m^2
    else echo "SKIP"; continue; fi
    BASE=$(git merge-base "$base_side" "$up")
    git diff -z --name-only "$BASE" "$up" | while IFS= read -r -d '' f; do
      git diff --quiet main feature -- "$f" || echo "DIFFERS: $f"
    done
  done | sort -u | tr '\n' ' '
)
case "$report" in
  *"DIFFERS: a.txt"*) pass "drop from the first merge found" ;;
  *) fail "first merge's drop missed: $report" ;;
esac
case "$report" in
  *"DIFFERS: b.txt"*) pass "drop from the second merge found" ;;
  *) fail "second merge's drop missed: $report" ;;
esac
case "$report" in
  *SKIP*) pass "sibling merge skipped, not reported as drops" ;;
  *) fail "sibling merge was not skipped: $report" ;;
esac

# Parents-swapped case, in its own fixture: the merge was made FROM the upstream
# side, so ^1 is upstream and ^2 is the branch. The recipe must still find the
# drop rather than skipping the merge.
swaprepo="$TMP/p2c"; mkdir -p "$swaprepo"
swapped=$(
  cd "$swaprepo" || exit 1; git init -q .
  echo base > a.txt; git add -A; git commit -qm base; git branch -q topic
  echo up > a.txt; git commit -qam upstream-change; upstream=$(git rev-parse HEAD)
  git checkout -q topic; echo branchver > a.txt; git commit -qam topic-change
  # Merge made FROM the upstream side (^1 = upstream, ^2 = the branch), resolved
  # in favour of the branch — so upstream's change to a.txt is dropped.
  git checkout -q main
  git merge --no-commit --no-ff topic >/dev/null 2>&1
  git checkout topic -- a.txt
  git commit -qm "Merge branch 'topic' into main"
  git branch -f topic HEAD
  git reset -q --hard "$upstream"     # main back to plain upstream
  git checkout -q topic

  for m in $(git rev-list --merges main..topic); do
    if git merge-base --is-ancestor "$m^2" main; then up=$m^2; base_side=$m^1
    elif git merge-base --is-ancestor "$m^1" main; then up=$m^1; base_side=$m^2
    else echo "SKIP"; continue; fi
    BASE=$(git merge-base "$base_side" "$up")
    git diff -z --name-only "$BASE" "$up" | while IFS= read -r -d '' f; do
      git diff --quiet main topic -- "$f" || echo "DIFFERS: $f"
    done
  done | sort -u | tr '\n' ' '
)
check "parents-swapped merge is examined, not skipped" "DIFFERS: a.txt " "$swapped"

# The all-clear trap, in its own fixture so it cannot disturb the one above:
# once the base contains the branch, the range is empty and the loop would
# print nothing at all, which reads as "no drops found".
landedrepo="$TMP/p2b"; mkdir -p "$landedrepo"
(
  cd "$landedrepo" || exit 1; git init -q .
  echo a > a.txt; git add -A; git commit -qm base; git branch -q topic
  echo up > a.txt; git commit -qam upstream
  git checkout -q topic; echo t > t.txt; git add t.txt; git commit -qm topic-work
  git merge -q -s ours main -m "Merge branch 'main' into topic"
  git checkout -q main; git merge -q --no-ff topic -m "Merge topic"   # branch has landed
)
landed=$(
  cd "$landedrepo" || exit 1
  merges=$(git rev-list --merges main..topic)
  [ -n "$merges" ] || echo "no merges in range — did the branch already land?"
)
check "warns instead of printing an empty all-clear" \
      "no merges in range — did the branch already land?" "$landed"

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
# Carries the doomed.txt deletion and keep.txt, but NOT gone.txt's deletion and
# NOT the spaced path — so both must be reported, which is what makes the -z
# handling and the ABSENT sentinel observable.
git rm -q doomed.txt; echo k2 > keep.txt
git commit -qam "split1: carries the deletion and keep.txt only"
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

check "uncarried deletion and spaced path both reported" \
      "NOT CARRIED: gone.txt NOT CARRIED: sp ace.txt " "$(run_split split1)"

out=$(run_split split1 typo-branch 2>&1); rc=$?
check "an unresolvable branch name aborts instead of masking a miss" "1" "$rc"
check "and says which name" "no such branch: typo-branch" "$out"

# The suite must notice when an assertion stops running at all — the failure
# mode that `cmd && pass` used to produce silently.
check "every assertion ran" "24" "$ran"

printf '\n---- assertions: %s, failures: %s\n' "$ran" "$failures"
[ "$failures" -eq 0 ]
