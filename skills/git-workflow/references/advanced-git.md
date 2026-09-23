# Advanced Git Operations

## Shallow Fetches

### `--depth=1` truncates the WHOLE repository, not the refs you asked for

`git fetch --depth=1 origin '+refs/heads/*:refs/remotes/origin/*'` looks like it
scopes to the refs in its refspec. It does not. It writes `.git/shallow` and
every ancestry query in that checkout answers from a one-commit graft
afterwards.

```bash
git clone --no-local file://$REPO probe && cd probe
git rev-list --count HEAD          # 366
git fetch --quiet --depth=1 origin '+refs/heads/*:refs/remotes/origin/*'
git rev-parse --is-shallow-repository   # true
git rev-list --count HEAD          # 1
```

Why it matters more than it looks: a shallow repository does not merely lack
objects, it **truncates ancestry**, so `git merge-base --is-ancestor X main`
answers "no" for a commit that genuinely is on `main`. Anything built on that
answer — a guard, a changelog generator, a release check — goes quietly wrong
rather than failing.

The usual shape is a CI job that fetches other branch heads cheaply, two lines
above the command that needs history. Both look innocent; only the pair is
wrong. If a job needs ancestry, it needs the history:

- GitLab: `GIT_DEPTH: 0` on that job, **and no `--depth` in any fetch the script
  runs**. The second half is the one that gets missed: a job can start with full
  history and lose it to a `--depth=1` line of its own three commands later.
- GitHub Actions: `actions/checkout` with `fetch-depth: 0`, same caveat.

`git fetch --unshallow` does recover a shallow checkout — with or without a ref
argument, and even where the remote's configured refspec is a single ref
(measured both ways). It is not a defence against the above, because a later
`--depth` fetch simply makes the repository shallow again; order decides.

A tool that depends on ancestry should say which state it is in rather than
answer from a truncated graph — `git rev-parse --is-shallow-repository` is one
call, and "I could not check" is a different answer from "this is fine".

## Rewriting History

### After ANY reset-based rebuild: the commit takes the INDEX, not the worktree

`git reset --soft <base>` + `git commit` is the standard way to collapse a
branch into one clean commit — and it commits whatever is **staged**, which
is the old tree, not the files as they lie on disk. Edits made after the last
`git add` (every editor/tool write) silently stay out, the commit "succeeds",
and only CI notices that the pushed tree is the stale one (2026-08-13: a
history rewrite meant to purge two files shipped without the accompanying
test/docs edits; the red CI on removed-file assertions was the first signal).

After the rebuild, before pushing:

```bash
git status --porcelain          # anything listed = NOT in the commit you just made
git grep -l <purged-artifact> HEAD   # verify against the COMMIT, not the worktree
```

Run the second command bare — behind a pipe (`| head`) `$?` is the pipe
tail's, and a "found it" exit code reads as clean.

### Interactive Rebase

```bash
# Rebase last N commits
git rebase -i HEAD~5

# Rebase from a specific commit
git rebase -i abc1234^

# Commands available:
# p, pick   - use commit
# r, reword - edit commit message
# e, edit   - stop for amending
# s, squash - combine with previous (keep message)
# f, fixup  - combine with previous (discard message)
# d, drop   - remove commit
# x, exec   - run shell command
```

### Replaying Only the Tip Onto a Moved Base (`--onto`)

Use when a long-lived branch is *N bootstrap commits + a few real commits*, and
the base branch has since absorbed that bootstrap work through a different path
(different SHAs). A plain `git rebase <base>` replays **all** N commits and hits
an add/add conflict on every file the base already recreated — and even after
resolving them the result is wrong.

```bash
# Symptom: the MR/PR diff shows an ENTIRE file as newly added (@@ -0,0 +1,N @@)
# even though the base already has that file. The merge-base predates the file,
# so base and branch each "add" it → add/add conflict. Don't trust the
# diff-vs-base; inspect the branch's own tip commit instead:
git show <tip>                        # the real change this branch introduces
git cherry -v <base> <branch>         # '+' = unique to branch, '-' = already in base
                                      #   (patch-id match; plain `log <base>..<branch>`
                                      #   still lists absorbed commits under new SHAs)

# Same command answers a second question, and it is the one that bites at
# cleanup time: "is this branch merged?" On a project that merges by REBASE
# (GitLab `rebase_merge`, GitHub "Rebase and merge"), the commits that land are
# new objects, so `merge-base --is-ancestor <branch> main` says NO for a branch
# whose content is entirely in main. Deleting on that answer feels unsafe;
# keeping on it leaves dead branches forever. `git cherry` compares patch-ids
# and gives the content answer:
git cherry origin/main <branch> | grep -c '^+'   # 0 = no commit carries a patch main lacks

# `git cherry` compares patch-ids, and patch-id NORMALISES WHITESPACE. Two
# commits that differ only in indentation have the same patch-id, so a branch
# whose sole change is a reformat reports 0 outstanding while its tree really
# does differ. Confirm with a tree comparison before deleting anything:
git diff --quiet origin/main...<branch> || echo "trees differ — do NOT delete on cherry alone"
git merge-base <base> <branch>        # confirm how far back it forks

# Replay ONLY the commits after <keep-base> onto the current base, dropping the
# redundant bootstrap history:
git rebase --onto origin/main <keep-base> <branch>
#            └ new base       └ everything up to AND INCLUDING this is dropped

# For a single tip commit, <keep-base> is its parent:
git rebase --onto origin/main <tip>~1 <branch>
```

Each replayed commit is 3-way merged against its own parent tree, so as long as
the lines it touches still exist verbatim in the new base it applies cleanly no
matter how far the base has moved. Verify the result is exactly the intended
change and nothing else:

```bash
git rev-list --count origin/main..HEAD   # == the number of real commits you kept
git diff origin/main..HEAD               # == the intended delta only
```

This is equivalent to cherry-picking just the tip commits onto the new base;
`--onto` does it in one step and preserves author and author-date. Force-push the
rewritten branch with `--force-with-lease`.

### Squashing Commits

```bash
# Squash last 3 commits
git rebase -i HEAD~3
# Change 'pick' to 'squash' for commits to combine

# Squash into a specific commit
git rebase -i <commit-before-first-to-squash>^

# Auto-squash fixup commits
git commit --fixup=<commit-hash>
git rebase -i --autosquash main
```

### Splitting Commits

```bash
# Start interactive rebase
git rebase -i HEAD~3

# Mark commit to split with 'edit'
# When stopped at that commit:
git reset HEAD^
git add file1.js
git commit -m "feat: first change"
git add file2.js
git commit -m "feat: second change"
git rebase --continue
```

### Reordering Commits

```bash
# Interactive rebase
git rebase -i HEAD~5

# In editor, reorder lines to reorder commits
# Example:
# pick abc1234 feat: feature A
# pick def5678 feat: feature B
# Changes to:
# pick def5678 feat: feature B
# pick abc1234 feat: feature A
```

## Cherry-Picking

### Basic Cherry-Pick

```bash
# Pick a single commit
git cherry-pick abc1234

# Pick multiple commits
git cherry-pick abc1234 def5678 ghi9012

# Pick a range
git cherry-pick abc1234^..def5678

# Cherry-pick without committing
git cherry-pick -n abc1234
```

### Cherry-Pick Options

```bash
# Keep original author
git cherry-pick -x abc1234

# Sign off
git cherry-pick -s abc1234

# Edit commit message
git cherry-pick -e abc1234

# Continue after conflict
git cherry-pick --continue

# Abort cherry-pick
git cherry-pick --abort
```

### Cherry-Pick Workflow

```bash
# Backport fix to release branch
git checkout release/1.0
git cherry-pick abc1234  # Fix from main
git push origin release/1.0

# Apply multiple fixes
git cherry-pick abc1234 def5678
# Or create a cherry-pick branch
git checkout -b cherry-pick-fixes release/1.0
git cherry-pick abc1234 def5678
git checkout release/1.0
git merge --no-ff cherry-pick-fixes
```

## Stashing

### A probe command is read-only

Comparing two revisions, checking what a script used to do, reproducing a bug
against an older build — that work is exploratory, and it must not move the
working tree. Never put `git stash`, `git reset`, `git checkout --` or
`git restore` inside a command whose purpose is to find something out.

The failure is silent, which is what makes it worth a rule. A probe that
stashes uncommitted work looks exactly like a probe that found nothing: the
command prints its output, the tree is quietly a different tree, and the next
edit lands on top of a state nobody chose. Recovery is `git stash pop`, but
only if you notice.

Extract the other revision instead of moving to it:

```bash
# ✅ Compare against another revision without touching the tree
git show origin/main:path/to/script.sh > /tmp/old-script.sh
bash /tmp/old-script.sh --check

# ✅ A whole old tree, still without moving
git worktree add /tmp/old-tree origin/main

# ❌ Wrong — mutates the working tree in the middle of an inspection
old=$(cd src && git stash -q; ./script.sh; true)
```

If a probe genuinely needs a clean tree, commit first (see the sibling rules on
selective revert and selective commit) — do not stash your way there.

### A control run must prove the change is gone, not assume the removal worked

The sibling rule above keeps stash out of a probe. This one is about the
opposite direction: using stash *deliberately* to remove your change so you can
measure the baseline. `git stash push -- <paths>` captures *uncommitted* work
for those paths — staged entries as well as unstaged edits, clearing the index
entry in the process — and nothing else. Once your change is committed there is
nothing left for it to take: it stashes nothing, exits 0, and prints a message
you skim past. The "control" then runs the very code it was supposed to
exclude.

That produces the most dangerous shape a measurement can have — a result that
confirms what you hoped, for a reason that has nothing to do with the code.
Both runs report identical numbers, you write "behaviour is unchanged", and the
evidence is a tautology. The only tell is that the matching `git stash pop`
fails with `No stash entries found`, at the end, after the conclusion is
already formed.

```bash
# ❌ Silently a no-op when the change is committed — both runs are identical
#    because both runs are the SAME code
git stash push -- config/app.php
./vendor/bin/phpunit                 # "baseline"
git stash pop

# ✅ For a committed change, take the file back to the base revision.
#    `git checkout <rev> -- <path>` overwrites index AND worktree for that path,
#    and the restore below returns it to HEAD — not to edits you had in flight.
#    So start from a clean tree, or do this in a throwaway worktree.
set -euo pipefail   # a failed checkout or status must abort, not be stepped over

st=$(git status --porcelain)
[ -z "$st" ] || { echo 'dirty tree, refusing'; exit 1; }

git checkout <base-sha> -- config/app.php

# grep exits 0 = found, 1 = absent, 2 = could not read. Only 1 proves absence,
# so branch on the code: `grep -q … && fail` treats a read error as "absent"
# and waves the baseline through, and a bare `grep -n` succeeds when the
# construct is still THERE, which is the same hole facing the other way.
set +e; grep -q 'theConstructYouRemoved' config/app.php; rc=$?; set -e
[ "$rc" -eq 1 ] || { echo "still present or unreadable (grep exit $rc)"; exit 1; }

./vendor/bin/phpunit                              # real baseline

git checkout HEAD -- config/app.php               # restore
st=$(git status --porcelain)
[ -z "$st" ] || { echo 'tree not restored'; exit 1; }
```

Whatever mechanism you use, assert the removal before you measure and assert the
restoration afterwards, and make both assertions fail loudly — a check that
exits 0 whether or not the condition holds is decoration. Neither costs a
second, and without them a green A/B says nothing at all.

### Basic Stash Operations

```bash
# Stash current changes
git stash

# Stash with message
git stash save "Work in progress on feature X"

# List stashes
git stash list

# Apply latest stash (keep in stash list)
git stash apply

# Apply and remove from stash list
git stash pop

# Apply specific stash
git stash apply stash@{2}

# Drop a stash
git stash drop stash@{1}

# Clear all stashes
git stash clear
```

### Advanced Stashing

```bash
# Stash including untracked files
git stash -u

# Stash including ignored files
git stash -a

# Stash specific files
git stash push -m "message" file1.js file2.js

# Create branch from stash
git stash branch new-branch stash@{0}

# Show stash contents
git stash show stash@{0}
git stash show -p stash@{0}  # With diff

# Partial stash (interactive)
git stash -p
```

## Bisecting

### Finding Bug Introduction

```bash
# Start bisect
git bisect start

# Mark current as bad
git bisect bad

# Mark known good commit
git bisect good v1.0.0

# Git will checkout middle commit
# Test, then mark:
git bisect good  # If bug not present
git bisect bad   # If bug present

# Continue until found
# Git reports: "abc1234 is the first bad commit"

# End bisect
git bisect reset
```

### Automated Bisect

```bash
# Run script at each step
git bisect start HEAD v1.0.0
git bisect run npm test

# With custom script
git bisect run ./test-for-bug.sh

# Exit codes:
# 0     - good
# 1-124 - bad
# 125   - skip (can't test this commit)
# 126+  - abort bisect
```

### Bisect Log

```bash
# Show bisect log
git bisect log

# Save bisect log
git bisect log > bisect.log

# Replay bisect
git bisect replay bisect.log
```

## Reflog

### Understanding Reflog

```bash
# Show reflog
git reflog

# Show reflog for specific ref
git reflog show main
git reflog show HEAD

# Output:
# abc1234 HEAD@{0}: commit: feat: add feature
# def5678 HEAD@{1}: checkout: moving from main to feature
# ghi9012 HEAD@{2}: commit: fix: bug fix
```

### Recovering Lost Commits

```bash
# Find lost commit in reflog
git reflog

# Recover commit
git checkout abc1234
git checkout -b recovered-branch

# Or cherry-pick
git cherry-pick abc1234

# Recover after bad reset
git reflog
git reset --hard HEAD@{2}
```

### Reflog Expiration

```bash
# Default: 90 days for reachable, 30 for unreachable
git config gc.reflogExpire 90.days
git config gc.reflogExpireUnreachable 30.days

# Expire reflog manually
git reflog expire --expire=now --all
git gc --prune=now
```

## Worktrees

### Multiple Working Directories

```bash
# Add worktree
git worktree add ../project-feature feature-branch

# Add worktree with new branch
git worktree add -b new-feature ../project-new-feature main

# List worktrees
git worktree list

# Remove worktree
git worktree remove ../project-feature

# Prune stale worktree info
git worktree prune
```

### Leave the worktree before you remove it

`git worktree remove` deletes the directory, including the one your shell may be
sitting in. The removal itself succeeds, so nothing looks wrong — the damage
shows up in the *next* commands, which run in a directory that no longer exists:

```
fatal: not a git repository (or any of the parent directories): .git
pwd: error retrieving current directory: getcwd: cannot access parent directories
```

Both read like a broken repository or a bad `-C` path, and that is the trap:
the repository is fine, the shell's cwd is a ghost. It bites hardest in agent
and script sessions, where `cd` persists between calls and the removal often sits
several commands before the failure.

Make the cleanup end somewhere that still exists:

```bash
cd /path/to/project/main            # or any surviving directory
git worktree remove /path/to/project/feature-x
```

Give the removal an absolute path, not a relative one resolved from inside the
target. Leave `--force` off unless you mean it: without the flag the command
refuses a worktree with uncommitted changes, which is the check that catches a
removal you did not intend. If a later command already failed this way, `cd` to a real directory
and re-run it — do not start diagnosing the repository.

**That check only covers tracked files.** Everything `.gitignore` matches is
deleted without a prompt and without `--force` being involved: build output,
caches, a local `.env`, and whatever a job or a script wrote into the worktree.
Those are exactly the files that exist in no other copy, and git offers nothing
to recover them from — they were never in the object store.

Measured on git 2.55.0: a worktree holding an ignored `.env` and an ignored
`build/out.txt` was removed by a plain `git worktree remove` with exit 0, no
warning, and both files gone. Read what would be lost before removing:

```bash
git -C <worktree> status --porcelain --ignored   # `!!` lines are what dies silently
```

#### A background process keeps the cwd it started with

Moving the shell out first does not save a process that is already running
there. A watcher started earlier — a pipeline waiter, a `tail -f`, a poll loop —
holds the removed directory as its cwd, and the failure surfaces at the wrong
moment and in the wrong place: it exits non-zero with the same `getcwd` message
*after* it has already printed its result, so the harness reports the task as
failed while the thing being watched succeeded.

```
tick 5: 265071 success
TERMINAL: 265071 success
pwd: error retrieving current directory: getcwd: cannot access parent directories
[exited with code 1]
```

Two habits. Start anything that outlives one command from a directory the work
will not remove — put the `cd` inside the script rather than relying on the
caller's cwd. And when a background task reports failure, read the last lines of
its output before the exit code becomes a statement about what it was watching.

#### A worktree containing submodules needs `--force`

The plain form refuses a worktree that has submodules checked out:

```
$ git worktree remove ../feature-x
fatal: working trees containing submodules cannot be moved or removed
```

The message reads like a prohibition, and the branch cannot be deleted while the
worktree stands (`error: cannot delete branch 'x' used by worktree at …`), so it
is easy to conclude the worktree has to be torn down by hand. It does not:
`--force` removes it (measured on git 2.55.0; the refusal is the submodule
check, and `--force` lifts it).

```bash
git -C <worktree> status --porcelain                 # must be empty
git -C <worktree> log --oneline origin/main..HEAD    # must be empty
git -C <worktree> stash list                         # must be empty
git -C <worktree> submodule foreach --quiet --recursive \
    'git stash list'                                 # must be empty — see below

git worktree remove --force /path/to/project/feature-x
git branch -d feature-x
git fetch origin --prune       # only where the remote branch is already gone
```

`--prune` drops `origin/feature-x` only if that branch no longer exists on the
remote — it removes refs whose upstream is gone, and nothing above deletes
anything on `origin`. After a merge on a forge that removes the source branch
(GitLab's `remove_source_branch_after_merge`, GitHub's auto-delete) the ref is
already stale and the prune tidies it; otherwise the remote branch is still
live and the ref belongs there.

**Never put `--prune` on a fetch whose refspec names its source in shorthand.**
The two are individually correct and destructive together: `--prune` prunes
against the refspec of the *invocation*, so that one mapping becomes the entire
set of refs git considers current — and an unqualified source (`main`) is not
matched against the ref the remote advertises (`refs/heads/main`), so the
destination looks stale. Git deletes the very ref the same command is about to
update, and the update then fails because its destination no longer resolves:

```console
$ git -C .bare fetch origin main:refs/remotes/origin/main --prune
 - [deleted]         (none)     -> origin/main
   refs/remotes/origin/HEAD has become dangling after refs/remotes/origin/main was deleted
error: cannot lock ref 'refs/remotes/origin/main': unable to resolve reference 'refs/remotes/origin/main'
 ! 3098286..5872596  main       -> origin/main  (unable to update local ref)
```

Afterward `origin/main` is deleted and `refs/remotes/origin/HEAD` survives as a
**dangling symbolic ref**: the file still points at `refs/remotes/origin/main`,
which no longer resolves. `for-each-ref refs/remotes/origin` then prints
nothing at all, because it skips refs it cannot resolve — do not read that as
both refs having been removed.

Reproduced on git 2.55.0 in a throwaway bare clone. Three neighbouring forms,
each differing in one thing, all leave both refs intact — so it is the shorthand
source specifically, not `--prune` and not a single-branch refspec:

```bash
git fetch origin --prune                                          # configured refspec — fine
git fetch origin '+refs/heads/*:refs/remotes/origin/*' --prune    # glob refspec — fine
git fetch origin refs/heads/main:refs/remotes/origin/main --prune # qualified source — fine
```

`git-fetch(1)` states the principle under PRUNING — pruning works "as a function
of the refspec of the remote" — but spells out only the tag version of the trap
(`refs/tags/*:refs/tags/*` deleting local tags), not this one.

The combination is easy to reach by accident in a bare-repo layout, because the
explicit-refspec fetch is the form that layout otherwise requires: `origin/*`
does not update on its own there, so `fetch origin <branch>:refs/remotes/origin/<branch>`
is the habit — written with the branch name, which is the shorthand form — and
adding `--prune` to tidy up after a merge looks like two safe things at once.
**Repair** is the same fetch without `--prune`; `origin/HEAD` starts resolving
again by itself once its target exists, so it needs no separate `symbolic-ref`.
Prune in its own call, or qualify the source as `refs/heads/<branch>`.

The reads are not optional here. Everywhere else `--force` is the flag you
leave off so the uncommitted-changes check can catch a removal you did not
intend; with submodules you need it for an unrelated reason, and that check goes
with it. Run the reads yourself before the flag, not instead of them.

The fourth read is the one that is easy to leave out, and it is the one that
loses work. A stash belongs to the repository it was created in, so a stash made
*inside* an initialized submodule is not in the superproject's `refs/stash` — and
because stashing reverted the change, the submodule is clean from the
superproject's side too. Measured on git 2.55.0, with a stash sitting in
`vendor/lib`:

```
git -C <worktree> stash list        (empty)
git -C <worktree> status --porcelain (empty)
git -C <worktree>/vendor/lib stash list
  stash@{0}: On (no branch): work in the submodule
```

All three superproject reads say "clean", and `git worktree remove --force`
then returns 0 and takes the linked worktree's submodule gitdir
(`$GIT_COMMON_DIR/worktrees/<id>/modules/<name>/`) with it, so the stash is gone
with no ref left to recover it from. `submodule foreach --recursive` is what
sees it; `--quiet` suppresses the `Entering '<path>'` lines so that empty output
means an empty stash rather than a header.

### "Merged and clean" is not the whole test — check the worktree's role

A cleanup sweep classifies worktrees by branch state: HEAD contained in
`origin/main`, tree clean, therefore safe to remove. That test is necessary and
not sufficient. It says nothing about *which* worktree it matched, and a
worktree the rest of the setup treats as the primary one can satisfy it too —
in the bare-repository layout (`project/.bare` plus one directory per branch,
`project/main`, `project/feature-x`), a `main/` directory that was switched to
a feature branch and left there stays behind after that branch merges, and then
classifies exactly like a disposable feature worktree. Git itself knows no such
role; the convention lives in the directory name, which is precisely why a
state-only classifier cannot see it.

Removing it deletes the directory every other tool, script and shell in that
repository points at. The fix for that case is a switch, not a removal:

```bash
git -C /path/to/project/main switch main     # fails if another worktree
                                             # already has main checked out
git -C /path/to/project/main fetch origin main
git -C /path/to/project/main merge --ff-only origin/main
git -C /path/to/project/main branch -d <merged-feature-branch>
```

The `fetch` is not optional: bare clones under this layout are often missing
`remote.origin.fetch`, so `origin/main` never moves on its own and the
`merge --ff-only` then silently does nothing while looking like it worked. If
the `switch` reports that `main` is checked out elsewhere, that other worktree
*is* the primary one — leave both alone and re-read the layout.

So the classifier needs two predicates, not one: the branch state **and** the
directory's role. Treat the worktree whose basename is `main`, `master` or the
repository's default-branch name as never-removable; only the others are
candidates for `git worktree remove`. In one sweep on 2026-08-15 over 171
bare-layout repositories holding 210 worktrees, 78 sat on a non-default branch;
12 of those passed the merged-and-clean test, and 9 of the 12 were primary
directories sitting on a merged feature branch — a role check that ran second
would have been a role check that ran too late.

The same shape applies to any cleanup rule that matches on state: state answers
whether the artifact is *finished*, never whether it is *disposable*.

### A stale worktree is a stale source

A worktree checked out days ago can be many commits behind `origin` — its
`composer.json`, its "what's on `main`", its API signatures are all whatever they
were at that checkout, not now. Before basing a **decision** on what a repo
contains — a dependency version constraint, whether a fix already landed on
`main`, a class/method signature you're about to code against — read the *current*
state, not the stale worktree:

```bash
git -C <repo> fetch origin && git -C <repo> log --oneline origin/main -3   # or:
git worktree add ../fresh origin/main                                      # read from a fresh tree
```

Three recurring failure modes:

- **Reporting a stale value as fact.** Reading `"^0.13"` from an un-fetched
  worktree and stating "the constraint needs bumping" — when current `main` already
  says `"^0.17 || ^0.18 || ^0.19"`. Verify against `origin/main` before writing the
  claim into a design or PR.
- **A subagent silently reads a stale checkout.** When you dispatch an agent to
  "read the source" for a decision, name the ref/worktree it must read, and
  re-verify its structural claims (config keys, signatures) against the current
  tree before building on them — half a report can come from an outdated path.
- **Running a *tool* from the stale worktree, not just reading it.** A script you
  merged an hour ago does not exist in a reference worktree that has not been
  fast-forwarded, so invoking it by path fails with `exit 127` — which reads as a
  broken command, a bad `PATH`, a typo, anything but "the tree is old". The
  remedy is one line, and it belongs at the end of a merge rather than at the
  start of the next debugging session:

  ```bash
  git -C <repo>/.bare fetch origin --prune
  git -C <repo>/main merge --ff-only origin/main   # reference worktree usable again
  ```

  Note `--ff-only`: a reference worktree that cannot fast-forward has local
  commits and is not a reference worktree any more, which is worth finding out
  loudly. Note also that the fetch above carries no refspec: adding the usual
  `main:refs/remotes/origin/main` next to `--prune` deletes `origin/main`
  outright (see *Never put `--prune` on a fetch whose refspec names its source
  in shorthand* above). In a bare-repo layout `origin/*`
  does not update on its own, so the fetch is not optional — and after a merge the *branch* worktree is usually gone,
  which is exactly when scripts start being invoked from `main/` instead.

Confirm the constructor/signature at the **resolved** dependency version (the one
installed in `vendor`/`.Build`), not the library's `main` branch — they drift
(e.g. a value object gaining a required constructor arg between minor releases).

### Bare-Repo Layouts

With the bare-clone convention (`project/.bare` + one directory per branch),
relative `worktree add` paths resolve from *inside* `.bare` — see the detailed
path-resolution rules and recovery steps in the bare-repo section below.

Before nesting a `.bare` into an existing directory, check whether it already
holds a **plain clone** — mixing the two layouts leaves a repo checkout *and* a
worktree side by side in one directory. If it already does, see "Consolidating a
plain clone into the bare layout" below for how to resolve it without losing
anything.

A reuse guard like `[ -d .bare ] || git clone --bare <url> .bare` silently *keeps*
whatever `.bare` is already there — which may point at a **different remote** than
you intend. Two repos can share a short name across hosts (GitHub
`netresearch/renovate-config` vs GitLab `renovate/renovate-config`) with entirely
different content, so a worktree off the wrong bare reads the wrong repo. After
reusing or creating a `.bare`, verify the remote before trusting anything read
from it:

```bash
git -C .bare remote get-url origin   # must match the intended remote
```

**`git clone --bare` leaves `remote.origin.fetch` empty, and that breaks
`--force-with-lease`.** Without a refspec the clone creates no `refs/remotes/*`
at all, so the lease has no recorded remote state to compare against and the
push is rejected:

```text
 ! [rejected]        HEAD -> feature (stale info)
```

The message reads as "somebody else pushed", which is the trap — nobody did, and
the reflex it invites is `--force`, dropping the protection entirely. Two
remedies, both measured on git 2.55.0. Give the lease its value explicitly:

```bash
SHA=$(git ls-remote origin refs/heads/<branch> | cut -f1)
git push --force-with-lease=<branch>:"$SHA" origin HEAD:<branch>
```

Or repair the clone once, after which the ordinary form works and `origin/*`
starts tracking:

```bash
git -C .bare config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'
git fetch origin
```

The second is what a long-lived bare layout wants: with no refspec, `git fetch
origin` updates nothing, so every later "is my branch behind?" question is
answered from refs that never move.

Skipping this once meant building an ADR off a *different* repo's config until a
version/branch mismatch exposed it.

### Consolidating a plain clone into the bare layout

When a directory holds both — a plain clone *and* a `.bare` added later —
consolidating means deleting one repository's object store. The checks that make
that safe are not the ones `git status` offers.

**Resolve the project path to an absolute one first.** `git -C "$bare"` makes
`.bare` git's working directory, so every relative path in these commands gains a
second `<project>` component — the same trap as `worktree add` below, and here it
would fetch from nowhere and put the worktree inside `.bare`.

**A ref is preserved when some ref in the survivor contains it**, which is not
the same as being an ancestor of `origin/main`. An unmerged side branch preserves
a sha perfectly well, and the ancestry test would condemn it — the mirror of the
squash-merge case in "Is This Branch Safe to Delete?" below.

**Enumerate every ref, not just `refs/heads`.** A commit can be held by a tag or
the stash and by no branch at all: `branch --contains` reports it as absent in
both repositories, so a branch-only sweep never asks about it and the loss is
silent. `for-each-ref --contains` searches all refs and names the one that
answers; empty output is the finding.

**Notes are a different shape and no ancestry check sees them.** A notes ref is
its own history, not an ancestor of the commit it annotates, so it is accounted
for and rescued as a ref in its own right — the loop below lists it, and the
rescue needs its own refspec.

```bash
project=$(cd <project> && pwd)          # absolute — see above
old="$project/.git"; bare="$project/.bare"

git --git-dir="$old" for-each-ref --format='%(refname)' \
    refs/heads refs/tags refs/notes refs/stash |
  while read -r ref; do
    sha=$(git --git-dir="$old" rev-parse --quiet --verify "$ref^{commit}") || continue
    printf '%-45s %s\n' "$ref" \
      "$(git --git-dir="$bare" for-each-ref --contains "$sha" --format='%(refname)' | head -1)"
  done
# a blank second column is a ref that dies with the old repository
```

`refs/stash` covers only `stash@{0}`; the deeper entries are reflog, so the loop
above sees one of them however many there are. `git stash list` is what counts
them, and the rescue below is what preserves them.

**Three things `git status` will not tell you.** A stash is not in the working
tree and dies with the repository — `git stash list`, then `git stash show
--stat` on each; tool-generated churn is the common case, but that is a finding,
not an assumption. An ignored build artefact never shows without
`--ignored`. And a worktree registered here may live anywhere on disk.

**`prunable` is a broken registration, not an absent directory.** `git worktree
list` marks an entry prunable when it cannot resolve it; the directory may still
be sitting there with uncommitted work. `ls -d` each path before believing the
marker.

**Rescue before discarding.** The doomed `.git` is a valid fetch source, so
nothing has to reach the remote first:

```bash
git -C "$bare" fetch "$old" '+refs/heads/<branch>:refs/heads/<branch>'
git -C "$bare" fetch "$old" '+refs/tags/*:refs/tags/*'    # a refs/heads refspec carries no tags
git -C "$bare" fetch "$old" '+refs/notes/*:refs/notes/*'  # nor notes

# Stashes: EVERY entry, not just the top one. `+refs/stash:refs/stash` carries
# stash@{0} alone, and `stash branch` consumes entries one at a time while
# shifting the rest — so turn each into its own ref before touching the reflog.
git -C "$project" stash list --format='%H' | nl -ba | while read -r n sha; do
  git -C "$project" branch "rescue-stash-$n" "$sha"
done
git -C "$bare" fetch "$old" '+refs/heads/rescue-stash-*:refs/heads/rescue-stash-*'
```

**Park, don't delete.** The reflog is the one thing that is not in the other
repository. `find` moves dotfiles too and leaves the directory itself in place,
so a shell sitting in it survives:

```bash
find "$project" -mindepth 1 -maxdepth 1 ! -name .bare -exec mv {} <parked>/ \;
# GNU mv batches the same thing: -exec mv -t <parked>/ {} +
```

**The worktree you then add is stale and has no upstream.** `clone --bare` writes
no `[branch]` section, so `git pull` there has nothing to pull from, and the
local branch sits wherever the bare clone found it:

```bash
git -C "$bare" worktree add "$project/main" main
git -C "$project/main" merge --ff-only origin/main
git -C "$project/main" branch --set-upstream-to=origin/main main
```

`tests/test_advanced_git_recipes.sh` runs this sequence end to end.

### Bare-Worktree Project Layout (Recommended)

**One directory per branch; never switch branches in the same folder.**

Rationale: IDEs that index the tree (gopls, IntelliJ, VS Code) choke on in-place branch switches, and running parallel work on feature branches without losing the main-branch state is painful. Using a bare repo with per-branch subdirectories gives you parallel checkouts, cheap hotfix spin-ups, and a main checkout that's never "dirty because I was exploring".

```
/projects/<repo>/
├── .bare/          # bare git repository (clone --bare)
├── main/           # main branch worktree
├── feature-x/      # optional feature branch worktree
└── bugfix-y/       # optional bugfix branch worktree
```

**`main/` is reference only — all work happens in fresh worktrees.** `main/` exists for reading code, running `git fetch`, and serving as the base for new worktrees. Never commit, edit, or develop directly in it. Every task — feature, fix, release, experiment — gets its own fresh worktree on its own branch, cut from a freshly fetched `origin/main` (in this layout `origin/*` does NOT auto-update, so always fetch first):

```bash
git -C /projects/<repo>/.bare fetch origin
git -C /projects/<repo>/.bare worktree add -b <branch> /projects/<repo>/<branch> origin/main
```

Remove the worktree and the local branch once the PR merges.

**Set up a new project this way:**

```bash
cd ~/projects
mkdir <repo> && cd <repo>
git clone --bare <repository-url> .bare

# Make the bare clone behave like a regular origin fetch target.
cd .bare && git config remote.origin.fetch "+refs/heads/*:refs/remotes/origin/*" && cd ..

# Check out main into a named subdirectory.
git -C .bare worktree add ../main main
```

**Work on a new branch = create a new folder:**

```bash
git -C .bare worktree add ../feature-x feature-x    # or -b for a new branch
cd feature-x
# ... edit, commit, push ...
cd ..
git -C .bare worktree list          # audit trail of what's checked out
git -C .bare worktree remove ../feature-x   # clean up when the PR merges
```

**Any relative path argument is resolved relative to `.bare/`, not your shell's current directory** — `git -C <dir>` makes `<dir>` git's working directory for the whole command, including how it interprets the `<path>` argument to `worktree add`. This applies to every form of the command, regardless of whether `-b` comes before or after the path:

```bash
# WRONG — both of these land INSIDE the bare repo
git -C .bare worktree add -b feature-x feature-x origin/main
git -C .bare worktree add feature-x -b feature-x origin/main
# → creates .bare/feature-x as a worktree of the bare repo — the
#   worktree is functional (it has a .git file pointing at .bare),
#   but it violates the sibling-layout convention and confuses any
#   tooling that walks up looking for the repository root
```

Note on the branch argument: plain `worktree add <path> <branch>` requires the branch to already exist. To create a fresh branch at the same time, use `worktree add -b <branch> <path> <start>` as shown above, or create the branch separately first. Both forms have the same path-resolution behaviour.

**Prefer absolute paths.** They're unambiguous regardless of where the command runs from — important when scripts, agents, or `/loop`-style sessions construct the command without a fixed cwd. Sibling-relative `../` works for humans typing from the repo parent but is brittle anywhere else.

```bash
# RIGHT — absolute path (preferred; works from any cwd)
git -C /projects/<repo>/.bare worktree add -b feature-x /projects/<repo>/feature-x origin/main

# Also fine when you're certain of cwd — sibling-relative resolves
# against .bare/, so '..' lands next to it.
git -C .bare worktree add -b feature-x ../feature-x origin/main
```

Use `origin/main` as the start point, not local `main` — local `main` is only current if you explicitly fast-forwarded it after the fetch.

**Recovery if you already created the worktree in the wrong place:**

```bash
# Use absolute paths for BOTH source and destination. The -C .bare
# flag makes `worktree move` resolve relative paths against .bare/,
# so `.bare/feature-x` would be interpreted as `.bare/.bare/feature-x`
# and wouldn't find the misplaced worktree.
git -C /projects/<repo>/.bare worktree move \
  /projects/<repo>/.bare/feature-x \
  /projects/<repo>/feature-x
```

(Alternatively, drop `-C .bare` and run from the repo parent; then the
source `.bare/feature-x` resolves against that parent rather than
against `.bare/`.)

When removing a worktree leaves a dangling branch reference (e.g., after deleting the physical directory manually), `git worktree prune` in `.bare/` cleans up the metadata.

**Batch cleanup after a session of PRs:**

```bash
# For each branch whose PR landed, delete the worktree + local branch:
for wt in feature-x bugfix-y sync/template-foo; do
  git -C /projects/<repo>/.bare worktree remove --force /projects/<repo>/$wt
  git -C /projects/<repo>/main branch -D "$wt" 2>&1 | tail -1
done

# Remote-side pruning (delete stale remote-tracking refs):
git -C /projects/<repo>/main fetch --prune origin
```

**The explicit list is the point — never replace it with a directory glob.**
`for wt in feature-x bugfix-y …` is the record of what *this* session created.
A pattern like `for d in */release-v*` looks like the same loop with less
typing, but it cannot tell your worktrees from ones that were already there,
and `worktree remove --force` plus `branch -D` is not undoable from the shell.
Build the list as you create each worktree and iterate over that.

(Observed 2026-08-06: a 19-repo release sweep cleaned up with `*/release-v*`
and took out a leftover `release-v1.12.0` worktree and its branch from an
unrelated release months earlier. Nothing was lost only because that branch had
already been merged and tagged — `git branch -D` reports the dangling sha, but a
sweep that discards its output never sees it.)

Two habits make the blast radius survivable when the list is wrong anyway:

```bash
# 1. See what would go, before anything goes.
git -C /projects/<repo>/.bare worktree list

# 2. Prefer plain -d over -D: it refuses to delete an unmerged branch.
git -C /projects/<repo>/main branch -d "$wt" || echo "unmerged, kept: $wt"
```

### "Is This Branch Safe to Delete?" Is Not an Ancestry Question

`git merge-base --is-ancestor <branch> origin/main` answers *is this commit an
ancestor* — which is not the same question as *is this work safe to delete*. A
squash-merged PR puts the content on `main` under a single new commit, so the
branch's own SHAs are nowhere in `main`'s history and the ancestry test says
"unmerged" about work that shipped weeks ago. Rebase-merge does the same.

Both directions of that mistake matter:

- **Reporting it** as unmerged inflates the number of branches that look like
  unsaved work, and buries the few that genuinely are. (Observed 2026-08-06: a
  cleanup reported 18 unmerged branches; 10 had merged PRs, 6 had deliberately
  closed ones, and exactly 2 commits existed nowhere else — one of them a real
  bug fix that had never landed.)
- **Acting on it** is only safe in the conservative direction. Ancestry is a
  sufficient condition for "already on main", never a necessary one, so using it
  to *keep* is safe and using it to *delete* is not what makes deletion safe —
  what makes it safe is that ancestry never produces a false positive.

Ask the question you actually mean:

```bash
# Authoritative: what happened to the PR this branch belongs to?
gh pr list --repo "$R" --head "$B" --state all --json number,state --jq '.[].state'
glab api "projects/$P/merge_requests?source_branch=$B&state=all" | jq -r '.[].state'

# No PR, or the host is unreachable: is every commit patch-equivalent upstream?
git cherry origin/main "$B"     # "-" = an equivalent patch is upstream, "+" = not
[ "$(git cherry origin/main "$B" | grep -c '^+')" -eq 0 ] && echo "nothing unique"
```

`git cherry` compares patch-ids, so it sees through a rebase and through a
squash of a single-commit branch. It does *not* see through a squash of several
commits into one — there the PR state is the only honest answer. A branch whose
PR is `CLOSED` (not merged) holds work somebody deliberately dropped: that is a
judgment call for a human, not a mechanical delete.

### Sync the Base Before Branching (Stale-Base Trap)

A per-branch worktree layout makes it easy to branch from a checkout that is
weeks behind the remote. A feature branch's green pipeline only proves
correctness **against its base** — if the base has moved, a clean auto-merge can
combine your change with newer code in a way no pipeline ever tested, landing a
regression on the default branch.

Guard against it at both ends of the work:

```bash
# At the START of work in any worktree — a stale checkout is not proof
# a file is missing. Sync the base, then branch from the fresh tip.
git -C <worktree> status -sb
git -C <worktree> fetch origin main         # update origin/main directly, don't touch the current branch
git -C <worktree> switch -c feature/x origin/main

# BEFORE merging — rebase onto the current remote base so CI validates the
# REAL merge result, not the branch against a stale base.
git fetch origin
git rebase origin/main
```

**Note for bare-repo layouts:** a bare clone often lacks
`remote.origin.fetch`, so `git fetch origin` never updates `origin/<base>`.
Fetch the base branch explicitly — `git fetch origin main:refs/remotes/origin/main`
— or set the refspec once (see the bare-worktree setup above).

After any merge, verify structural invariants on the **merged base** (e.g. that
every cross-reference still resolves), not just on the branch — that is the only
check that catches a regression introduced by the merge itself.

### Cross-Worktree Static Analysis Gives False Positives

Running a static analyzer (Rector, php-cs-fixer, PHPStan, ESLint) from ONE
worktree against source files in ANOTHER resolves symbols through the *running*
worktree's autoloader/vendor, not the branch under test. When the other branch
changed a method signature, added an interface method, or renamed a symbol, the
analyzer sees a mismatch that does not exist on that branch — e.g. Rector's
`RemoveExtraParametersRector` "removing" arguments that match the branch's own
wider signature, or a type-resolution rule firing (or staying silent) because a
new interface method is absent from — or present only in — the running worktree.

This bites hardest in bare+worktree layouts where only one worktree has a built
`.Build/vendor` (or `node_modules`), so cross-worktree runs are the only local
option. Treat each such finding as suspect: real, or an artifact of resolving
against the wrong tree? CI runs each branch in isolation with its own install,
so **CI is authoritative** — reproduce a doubtful finding by building deps inside
the target worktree, or defer to CI, rather than "fixing" a phantom.

### Corrupt Per-Worktree Index: `fatal: unable to read <sha>`

When `git status`, `git diff --staged`, or a pre-commit hook in a linked
worktree dies with `fatal: unable to read <sha>`, and `git fsck` reports
`invalid sha1 pointer in cache-tree of worktrees/<wt>/index` plus "missing
blob"s that only the index references (phantom entries for files in neither
HEAD nor the working tree), the worktree's **private index file** is corrupt —
the object store and your edits are fine.

The complete fix, losing nothing (working-tree files, including uncommitted
edits, are untouched):

```bash
rm <gitdir>/worktrees/<wt>/index     # e.g. .bare/worktrees/release-1.8.0/index
git -C <worktree> read-tree HEAD     # rebuild the index from HEAD
git -C <worktree> status             # edits reappear as modified; re-stage them
```

Per-path repair (`git restore --staged <path>`) is NOT enough when the
cache-tree itself is broken: the next command fails on the next missing blob.
Deleting the index is the whole fix. (Observed twice in one 2026-08-27 fleet
sweep, in freshly created release worktrees; the first repair attempt went
per-path and hit the second phantom blob immediately.)

### Use Cases

```bash
# Work on hotfix while keeping feature work
git worktree add ../project-hotfix hotfix/critical-bug
cd ../project-hotfix
# Fix bug
git commit -am "fix: critical bug"
cd ../project-main

# Review PR without stashing
git worktree add ../pr-review origin/feature-branch
cd ../pr-review
# Review code
```

### Pushing to Fork Remotes (Multiple Remotes Pitfall)

When using worktrees with multiple remotes (e.g., `origin` = upstream, `fork` = your fork),
`git push fork main` can silently say "Everything up-to-date" even when the fork is behind.

**Why it fails:**
- Local `main` tracks `origin/main` (upstream), not `fork/main`
- `git push fork main` resolves the tracking ref, which may already match what git considers current
- The fork remote never receives the new commits

**Fix: Use explicit refspec with `HEAD:main`**

```bash
# WRONG - may silently do nothing
git push fork main

# CORRECT - explicitly pushes current HEAD to fork's main
git push fork HEAD:main
```

**Full pattern for syncing a fork:**

```bash
# In a worktree where origin=upstream, fork=your-fork
git fetch origin
git merge --ff-only origin/main   # Update local main from upstream
git push fork HEAD:main            # Explicitly push to fork
```

**Rule:** When pushing to a non-tracking remote, always use explicit refspec
(`HEAD:<branch>` or `<local-branch>:<remote-branch>`) to avoid silent no-ops.

### Rebasing a PR Whose Head Lives on a Fork

The section above assumes you know which remote to push to. For an open pull
request you do not: the head branch may live in the upstream repo, in your
personal fork, or in an organisation fork, and `origin` is none of those by
default. Pushing a rebased branch to `origin` does not fail — it **creates a new
branch in the upstream repository** and leaves the pull request untouched, so
the rebase looks done and nothing about the PR changed.

Resolve the head repository before the push:

```bash
gh pr view <n> --repo OWNER/REPO \
  --json number,headRepositoryOwner,headRepository,headRefName \
  --jq '"\(.headRepositoryOwner.login)/\(.headRepository.name) \(.headRefName)"'
# -> some-org/repo refactor/modernize-float-classes
```

Add that repository as its own remote and push there:

```bash
git -C .bare remote add nrfork git@github.com:some-org/repo.git
git -C <worktree> push --force-with-lease=<branch>:<sha> nrfork HEAD:<branch>
```

**The lease needs the remote's real SHA, not a short one you expanded.** With
`--force-with-lease=<branch>:<sha>` git compares that value against the remote
ref; a SHA typed out from an abbreviated one is simply a different object name
and the push is rejected with `stale info`, which reads like someone else
pushed. Take the value from a fetch:

```bash
git -C .bare fetch nrfork <branch>
git -C .bare rev-parse nrfork/<branch>      # use exactly this in the lease
```

**If you pushed to the wrong remote:** the branch is a stray in the upstream
repo, delete it (`git push origin --delete <branch>`) and push again to the
head repository. The pull request never saw the wrong push, so nothing else
needs repairing — but check `gh pr view <n> --json headRefOid` afterwards to
confirm the PR now points at the rebased commit.

**Fetch every fork before a batch of rebases.** With three PRs on two forks,
one `git fetch --all` up front turns three lease lookups into local reads and
makes "which of these is behind main?" a single loop over `git merge-base`.

## Submodules

### Adding Submodules

```bash
# Add submodule
git submodule add https://github.com/org/repo.git libs/repo

# Add at specific branch
git submodule add -b main https://github.com/org/repo.git libs/repo

# Initialize submodules after clone
git submodule init
git submodule update

# Clone with submodules
git clone --recurse-submodules https://github.com/org/main-repo.git
```

### Updating Submodules

```bash
# Update all submodules to latest
git submodule update --remote

# Update specific submodule
git submodule update --remote libs/repo

# Update and merge
git submodule update --remote --merge

# Pull in main repo and submodules
git pull --recurse-submodules
```

### Submodule Commands

```bash
# Run command in all submodules
git submodule foreach 'git pull origin main'

# Check status
git submodule status

# Remove submodule
git submodule deinit libs/repo
git rm libs/repo
rm -rf .git/modules/libs/repo
```

## Git Hooks

> **Comprehensive guide**: See [`git-hooks-setup.md`](git-hooks-setup.md) for hook framework
> comparison (lefthook, captainhook, husky, pre-commit), detection logic, and agent rules.

### Client-Side Hooks

```bash
# .git/hooks/pre-commit
#!/bin/bash
npm run lint
npm run test

# .git/hooks/commit-msg
#!/bin/bash
# Validate commit message format

# .git/hooks/pre-push
#!/bin/bash
npm run test:e2e
```

### Server-Side Hooks

```bash
# hooks/pre-receive
#!/bin/bash
# Validate pushes before accepting

# hooks/post-receive
#!/bin/bash
# Deploy after push accepted

# hooks/update
#!/bin/bash
# Per-branch validation
```

### Hook Management with Husky (Node.js)

```json
// package.json
{
  "husky": {
    "hooks": {
      "pre-commit": "lint-staged",
      "commit-msg": "commitlint -E HUSKY_GIT_PARAMS",
      "pre-push": "npm test"
    }
  },
  "lint-staged": {
    "*.{js,ts}": ["eslint --fix", "prettier --write"]
  }
}
```

Other frameworks: **lefthook** (Go, `lefthook.yml`), **captainhook** (PHP, `captainhook.json`),
**pre-commit** (Python, `.pre-commit-config.yaml`). See [`git-hooks-setup.md`](git-hooks-setup.md).

## Advanced Merging

### Merge Strategies

```bash
# Recursive (default)
git merge feature

# Ours (keep our changes)
git merge -s ours feature

# Subtree (merge into subdirectory)
git merge -s subtree --allow-unrelated-histories other-repo/main

# Octopus (merge multiple branches)
git merge feature1 feature2 feature3
```

### Merge Options

```bash
# No fast-forward
git merge --no-ff feature

# Squash merge
git merge --squash feature

# Merge with message
git merge -m "Merge feature X" feature

# Abort merge
git merge --abort
```

### Rerere (Reuse Recorded Resolution)

```bash
# Enable rerere
git config rerere.enabled true

# After resolving conflict, it's recorded
# Next time same conflict occurs, auto-resolved

# View recorded resolutions
git rerere status

# Forget resolution
git rerere forget path/to/file
```

## Git Attributes

### Line Endings

```bash
# .gitattributes
* text=auto
*.sh text eol=lf
*.bat text eol=crlf
*.png binary
```

### Diff and Merge

```bash
# .gitattributes
*.min.js binary
*.lock -diff
*.pdf diff=pdf

# Custom diff driver
[diff "pdf"]
  textconv = pdftotext -layout
```

### Export Ignore

```bash
# .gitattributes
.gitignore export-ignore
.github export-ignore
tests/ export-ignore
```

`export-ignore` removes a path from `git archive` — and from the tarball the
package registries build from it. It does not affect clones, checkouts or
worktrees.

**Never build a test workspace with `git archive`.** What a repository marks
`export-ignore` is what a *consumer* does not need, which is very close to what
a *test run* does need: `tests/`, the analyser and fixer configs, the CI config.
A workspace unpacked from `git archive` is missing exactly those, and the tools
do not agree on how loudly to say so.

```bash
mkdir -p /tmp/ws

# Wrong: silently drops every export-ignore'd path
git archive HEAD | tar -x -C /tmp/ws

# Right: the working tree, minus what the run reinstalls itself
tar -c --exclude=vendor --exclude=node_modules --exclude=.git . | tar -x -C /tmp/ws
(cd /tmp/ws && composer install --no-interaction)   # or npm ci, etc.
```

The exclusions are what the run reinstalls, so the install is part of the
recipe, not an afterthought: copy the tree without `vendor`, then put `vendor`
back. Skipping that second step leaves a workspace where no gate can run at all,
which is a different failure from the one this section is about.

Measured on such a workspace (2026-09-18, `TYPO3-Documentation/guides-php-domain`
at `5b4a38c`, PHP 8.2.30, vendor copied in from a full checkout so only the
export-ignored files were absent):

| Gate | Exit | What it did |
|---|---|---|
| `phpunit --testsuite=unit` | 2 | `Test directory "/app/tests/unit/" not found` |
| `phpstan --configuration=phpstan.neon` | 1 | config file gone |
| `php-cs-fixer check` | **0** | checked nothing, **wrote `.php-cs-fixer.dist.php` and `.gitignore` into the workspace**, printed `Config file created, re-run the command to put it in action.` |

The first two are loud. The third is the one that matters: a green exit from a
run that inspected zero files. Its output does say `Config file created`, so it
is not invisible to someone reading the log — but a gate that decides on the
exit status alone, which is most of them, cannot tell it from a clean run. It
also leaves the generated config behind, so the *second* run reports 33 of 49
files needing fixes against rules the project never chose. A tool that falls
back to defaults when its config is missing turns a truncated workspace into a
passing verification.

**The check, before the workspace is used for anything:** read the export rules,
then list the tracked files that did not arrive.

```bash
git check-attr export-ignore -- tests/ phpstan.neon   # "export-ignore: set" -> archive drops it

git ls-files -z | while IFS= read -r -d '' f; do
  [ -e "/tmp/ws/$f" ] || printf '%s\n' "$f"
done
```

Ask it in that direction — *which tracked files are missing* — rather than
diffing two file listings. A plain
`diff <(git ls-files) <(cd /tmp/ws && find . -type f)` drowns: run against the
archive workspace above it produced **8256** lines, of which 8134 were `vendor/`
and other untracked files present in the tree but not in git, and only 116 were
the answer. The loop prints those 116 and nothing else, and prints nothing at
all for a workspace copied with `tar`.

## Performance Optimization

### Large Repositories

```bash
# Shallow clone
git clone --depth 1 https://github.com/org/repo.git

# Sparse checkout
git clone --filter=blob:none --sparse https://github.com/org/repo.git
cd repo
git sparse-checkout set src/

# Partial clone
git clone --filter=blob:none https://github.com/org/repo.git
```

### Git LFS

```bash
# Install LFS
git lfs install

# Track large files
git lfs track "*.psd"
git lfs track "*.zip"

# View tracked patterns
git lfs track

# View LFS files
git lfs ls-files

# Pull LFS files
git lfs pull
```

#### Removing LFS without a history rewrite

LFS earns its keep for assets that are large *and* churn. For a working set
that is neither — 238 files / 39 MB in one demo repository — it costs the
org's monthly LFS bandwidth allowance instead: every `actions/checkout` with
`lfs: true` and every deploy-side `git lfs pull` fetches the whole set again,
and ~20 CI runs a day turned 39 MB into 1.5 GB/day (netresearch/typo3-demo#231,
2026-08-29). Moving the files back into plain git needs no `git lfs migrate
export` and no force-push:

```bash
# 1. Drop the tracking rules (delete the file if LFS was all it held).
git rm .gitattributes            # or: git lfs untrack '<pattern>' per rule

# 2. Re-store every tracked file as a plain blob. --renormalize is the point:
#    the stat cache still calls the files clean, so a bare `git add` stores
#    nothing; renormalize re-runs the (now absent) clean filter.
git add --renormalize .

# 3. Prove the conversion byte for byte: staged blob sha256 == LFS object id.
#    Process substitution, not a pipe — a `| while` runs in a subshell and
#    loses the counter, so nothing could ever fail. shasum covers macOS.
sha=$(command -v sha256sum >/dev/null && echo sha256sum || echo 'shasum -a 256')
bad=0
while read -r oid _ path; do
  [ "$(git cat-file blob ":$path" | $sha | cut -d' ' -f1)" = "$oid" ] \
    || { echo "MISMATCH $path"; bad=$((bad + 1)); }
done < <(git lfs ls-files -l)
[ "$bad" -eq 0 ] || { echo "$bad file(s) are not the LFS content — do not commit"; exit 1; }
```

Then strip every LFS *step* the repository carries — `lfs: true` on each
`actions/checkout` (grep the workflows: a reusable build workflow may take it
as an input), `git lfs pull` in deploy scripts, direnv/tool checks — and
commit with the files. The `git-lfs` *package* in host provisioning is a
separate decision: a host that can still deploy or roll back to a commit from
before the conversion needs it, or that checkout leaves pointer files where the
assets should be. Drop the package only once no pre-conversion commit is a
deploy target any more; until then it is harmless to keep. Two things to know
while doing it:

- `git lfs ls-files` reads **HEAD**, so it keeps reporting the old count until
  the commit exists; the staged tree is what to check (`git show :<path>`
  must not start with `version https://git-lfs.github.com/spec/v1`).
- Nothing changes on hosts that already hold a smudged checkout: their next
  `git pull --ff-only` replaces the files with identical content from the new
  blobs. Only a checkout of a commit *before* the conversion still needs
  `git-lfs` installed — say so in the PR body, and keep the package where
  that checkout is a rollback path (see above).

The LFS objects stay in the remote's LFS store (storage, not bandwidth, and
usually far inside the allowance); a history rewrite is the only way to drop
them, and for a few dozen MB it is not worth the force-push and the rebase of
every open PR.

### Repository Maintenance

```bash
# Garbage collection
git gc

# Aggressive gc
git gc --aggressive

# Prune unreachable objects — unlike plain `git gc`, this deletes them
# immediately (no gc.pruneExpire grace period). Don't run it while recovering
# a dropped stash — see "A popped/dropped stash is not immediately gone" below.
git prune

# Verify repository
git fsck

# Repack
git repack -a -d
```

## Scripting Over Tracked Files

### `git ls-files`, not `git ls-tree`, for glob pathspecs

When a script matches tracked files by a configurable glob, use `git ls-files` —
**not** `git ls-tree`. `ls-tree` rejects pathspec magic; the glob form dies:

```bash
git ls-tree -r HEAD -- ':(glob)docs/**/*.md'
# fatal: pathspec magic not supported by this command: 'glob', 'exclude'
```

If that command is wrapped in `2>/dev/null` (common in guard scripts), the fatal
error is swallowed and you get a **silently empty** result — a false negative
that lets unguarded files through. `ls-files` honors `:(glob)` and
`:(exclude,glob)`:

```bash
git ls-files -- ':(glob)docs/**/*.md' ':(exclude,glob)docs/_build/**'
```

**Caveat — `ls-files` lists the index (staged *and* committed).** A freshly
staged file therefore shows up as "tracked". For a committed-only view (or to
avoid double-counting a file you just staged), compute the staged set first and
subtract it:

```bash
staged=$(git diff --cached --name-only --diff-filter=ACMR)
if [ -n "$staged" ]; then
  git ls-files -- ':(glob)docs/**/*.md' | grep -vxF "$staged"
else
  git ls-files -- ':(glob)docs/**/*.md'
fi
```

Use `--diff-filter=ACMR` (not just `AM`) so renames and copies into a guarded
path are caught. Verify pathspec support empirically before swapping one
command for the other — the failure mode is silent, not loud.

## Reading a File As It Is Committed on Another Branch

To see what a file *actually contains on another branch or ref* — without
switching to it — read it from the object store:

```bash
git show <branch>:<path>          # e.g. git show origin/main:src/App.tsx
git show <tag>:<path>
git show <sha>:<path>
```

Use this instead of trusting the working-tree copy right after a `git checkout`.
A branch switch swaps every file on disk, so the on-disk copy (and any editor or
harness "file was modified" notice fired by the switch) reflects the branch you
landed on, not the one you were reasoning about — chasing that phantom "edit" is
a real time sink. `git show <branch>:<path>` answers "what's committed there?"
authoritatively; reserve the working tree for "what's staged/unsaved here now?".

To compare a file across branches without checkout, use
`git diff <branchA> <branchB> -- <path>` (or `git diff <branchA>...<branchB> -- <path>`
for the merge-base–relative diff).

### Never `git checkout <ref> -- <path>` while the change is uncommitted

One exemption, stated where it applies: resolving a *still-unedited* conflicted
path from a reference merge — see "A long rebase needs a reference merge to
resolve against" below.

`git checkout <ref> -- <path>` overwrites the working-tree file **without
warning and without a reflog entry**. Uncommitted content is never written to
the object store, so there is usually nothing in Git to recover from — only an
editor's local history or a filesystem snapshot can still hold it. The pattern
that bites is comparing current behaviour against a baseline:

```bash
git checkout <base-ref> -- src/Service.php   # measure the old behaviour
# … run the probe …
git checkout HEAD -- src/Service.php         # "restore"
```

That last line restores the file as it is **committed**. If the fix you were
measuring was still only in the working tree, it is now gone, silently, and the
next `git add` commits the file without it. Observed cost: a commit pushed
without the fix it was created for, discovered only because the test output was
read line by line afterwards.

Use `git show <ref>:<path>` (above) to read the baseline instead — it never
touches the working tree. Where a baseline must genuinely be *on disk* (an
autoloader, a bundler), commit or stash first, or check the baseline out into a
throwaway worktree:

```bash
git worktree add /tmp/baseline <base-ref>
```

### Never chain `git push` behind a test run with `&&`

```bash
composer test | grep -E 'OK|FAILURES' && git add -A && git commit -s -m … && git push
```

This pushes on a failing suite. `&&` propagates the exit status of the **last**
command in the pipeline, and `grep` exits 0 as soon as it matches *anything* —
including the word `FAILURES`. Filtering test output for readability discards
the very status the chain depends on.

Run the suite as its own command, read the result, and only then commit and
push. If it must be one invocation, gate on the runner rather than the filter —
capture the runner's status explicitly, which works in any POSIX shell:

```bash
composer test > out.txt; rc=$?
grep -E 'OK|FAILURES' out.txt          # read it, but don't gate on it
[ "$rc" -eq 0 ] || exit 1
```

(`set -o pipefail` does the same in bash, zsh and ksh, but it is not in POSIX
`sh` — a script with `#!/bin/sh` under dash will fail on it.)

#### `pipefail` makes `… | grep … || echo "not found"` lie

The `||` fallback beside a pipeline reads as "the grep found nothing". Under
`pipefail` it also fires when the grep *matched* and the command feeding it
failed, because the pipeline then carries the writer's status:

```bash
bash -c '(echo MATCH; exit 1) | grep -q MATCH; echo $?'                  # 0 — grep's
bash -c 'set -o pipefail; (echo MATCH; exit 1) | grep -q MATCH; echo $?'  # 1 — the writer's
```

The result is a message contradicting the output directly above it — a verifier
printing its findings and then "nothing found", or a guard visibly firing under
the line `GUARD DID NOT FIRE`. Both were observed within one session, and the
false line was believed once.

**The writer does not have to be broken.** `grep -q` exits at the first match,
which closes the pipe; a writer still pushing data then dies of SIGPIPE and the
pipeline carries *its* status. So the fallback fires on a match — the more input
there is, the more reliably:

```bash
set -o pipefail
out=$(awk 'BEGIN { for (i = 1; i <= 100000; i++) print "MATCH" }')
printf '%s\n' "$out" | grep -q MATCH || echo "pattern absent"   # prints it
```

This is what makes the trap durable: the same line passes on a one-line
fixture and fails on real data, so a test written alongside it agrees with the
bug.

Since `set -o pipefail` belongs at the top of every multi-step block, the
fallback is the part to change, not the option. Remove the pipe where the input
is already in hand — a here-string cannot SIGPIPE and has no pipeline status:

```bash
set -o pipefail
out=$(producer) || { echo "producer failed"; exit 1; }   # writer, on its own
grep -q PATTERN <<< "$out" || echo "pattern absent"      # reader, on its own
```

Where the producer must stream, read the grep's own status out of
`PIPESTATUS` — `$?` after a pipeline is the *pipeline's* status, so under
`pipefail` it is 141 (SIGPIPE) on exactly the match this is meant to detect:

```bash
set -o pipefail
producer | grep -q PATTERN
found=${PIPESTATUS[1]}          # 0 matched, 1 absent — $? here would be 141
[ "$found" -eq 0 ] || echo "pattern absent"
```

That also keeps a broken producer visible: `${PIPESTATUS[0]}` is its status, and
it is worth checking separately rather than folding into one verdict about the
data.

Afterwards verify what actually landed, on the remote rather than locally.
Match one unique line from the change — `grep -c` counts matching *lines*, so a
multi-line pattern will not match at all; `-F` avoids regex surprises in code:

```bash
git fetch <remote> <branch>
git show FETCH_HEAD:<path> | grep -cF '<one distinctive line of the fix>'
```

## Troubleshooting

### Common Issues

```bash
# Fix "detached HEAD"
git checkout -b new-branch  # If you want to keep changes
git checkout main           # If you want to discard

# Fix "refusing to merge unrelated histories"
git merge --allow-unrelated-histories other-branch

# Fix corrupted repository
git fsck --full
git gc --prune=now

# Remove file from all history
git filter-branch --force --index-filter \
  'git rm --cached --ignore-unmatch path/to/file' \
  --prune-empty --tag-name-filter cat -- --all
```

### Recovery Operations

```bash
# Recover deleted branch
git reflog
git checkout -b recovered abc1234

# Recover deleted file
git checkout HEAD~1 -- path/to/file

# Undo hard reset
git reflog
git reset --hard HEAD@{1}

# Recover stash — field-position parsing (not `cut -d' ' -f3`) survives locale
# translation (German fsck reorders the line to "unreachable commit <sha>"),
# and matching both `^WIP on ` (anonymous) and `^On ` (named via `stash push -m`)
# catches stashes `--grep=WIP` alone would silently miss.
git fsck --unreachable | awk '{for(i=1;i<=NF;i++) if ($i=="commit"){print $(i+1); break}}' | \
  xargs -r git log --no-walk --merges -E --grep='^WIP on |^On '
```

### A popped/dropped stash is not immediately gone

`git stash pop` and `git stash drop` remove the stash's ref from `git stash
list`, but the underlying commit object is not deleted — it becomes a
dangling commit, reachable by SHA. An ordinary `git gc` will not delete it
right away — `gc.pruneExpire` defaults to 2 weeks, so a freshly dangling
commit survives routine garbage collection. But don't assume any pruning
step is safe: a bare `git prune` (no `--expire`, same as `git gc
--prune=now`) removes unreachable objects immediately, no grace period —
including the plain `git prune` this file's own Repository Maintenance
recipe recommends. Do not conclude stashed changes are lost just because
they vanished from the working tree (e.g. an unrelated later step — a build
hook, `composer update`'s asset-publish lifecycle, another tool — silently
overwrote the same files) or because the stash is gone from `git stash
list` — but don't run maintenance commands against the repo either until
you've actually recovered it.

Git prints the commit SHA at pop/drop time (not on a `pop` that hits a
conflict — the stash then stays in `git stash list` instead) — keep that
line in view instead of letting it scroll away:

```
Dropped refs/stash@{0} (14386d701aad44499e677dbc4b3a3f613bb6405f)
```

Recover directly from that SHA:

```bash
git stash apply 14386d701aad44499e677dbc4b3a3f613bb6405f
```

If the SHA wasn't captured, find the dangling commit via `git fsck` (the
"Recover stash" recipe above) — `git reflog` will not help here: dropping or
popping a stash removes the entry from `refs/stash`'s own reflog (and if it
was the only stash, `refs/stash` disappears entirely, so `git reflog show
refs/stash` fails with "ambiguous argument"), and plain `git reflog` (HEAD)
never had a stash entry to begin with.

### Tags & Remote-State Topology

A plain `git fetch` auto-follows *new* tags on fetched commits, but it will not
move a tag that was **force-updated** upstream, nor drop one deleted upstream —
so local tag refs can silently point at stale commits. Before reasoning about tag
relationships — which tag is newest, whether X is an ancestor of Y, whether two
lines diverged — refresh the tags and treat the remote as authoritative. A stale
local tag can invent a divergence that does not exist.

```bash
# Force-update moved tags and prune deleted ones (--prune-tags needs Git >= 2.17;
# without it, drop the flag and re-fetch with --force)
git fetch origin --prune --prune-tags --force

# Nearest tag by commit ancestry (NOT the highest semver), plus a direct test
git describe --tags <branch>
git merge-base --is-ancestor <tag> <branch> && echo "reachable from branch"

# Authoritative ahead/behind/merge-base straight from the host
gh api repos/OWNER/REPO/compare/<base>...<head> \
  --jq '{status, ahead_by, behind_by, merge_base: .merge_base_commit.sha}'
```

Verify against `origin` (or the compare API) before deleting a tag, choosing a
release version, or concluding two lines forked — not against local refs.

## Rebasing a branch whose tip is a merge commit can collapse the PR

Plain `git rebase base` flattens/omits merge commits and skips patches whose patch-id is already upstream — if the branch's unique content lives *inside* a merge resolution, the rebase silently drops it, the branch becomes equal to base, and GitHub auto-closes the now-empty PR (content survives only in local reflog). After any batch rebase, verify `compare base...branch` shows `ahead >= 1` — `ahead = 0` means collapsed. Use `--rebase-merges` when the merge structure carries content. (Real case: a release-merge tip carried the feature edits; rebase → branch == main → PR auto-closed.)

## Never pipe state-changing git/CLI commands through tail/head in `&&` chains

`git pull --rebase 2>&1 | tail -1 && git tag …` is a double trap: the chain's exit code is tail's (always 0), and the one shown line is usually not the error. Burned repeatedly: tags created on stale pre-merge HEADs, a rejected push that "succeeded" on screen, a failed verification build that printed OK and let the push through. Gate steps run unpiped — redirect to a log, check `$?`, then read the log. Compounding race: `glab mr merge` returns before the merge commit exists, so an immediate pull can still see the old HEAD.

## Stage by name — never `git add -A`/`.` when legacy untracked files exist

A tree can hold untracked files the user explicitly keeps untracked; `-A`/`.` sweeps them into the commit, and after a push the cleanup needs a second commit (the add+delete stays in history). The staging step after a change is always: named files, or a named directory you fully own.

## Exclude a local-only working note in `.git/info/exclude`, not `.gitignore`

A note that must sit in the worktree but never be committed — an analysis a follow-up session reads, a temporary debugging scratch file — reaches for `.gitignore` by reflex. `.gitignore` is itself versioned, so the exclusion becomes a repo change everybody gets, for something purely local. `.git/info/exclude` takes the same syntax, applies to this clone only, and is not versioned; the file then shows up in neither `git status` nor `git add -A`. The tradeoff is the flip side of the same property: it lives inside `.git/`, so it does not survive a re-clone and reaches nobody else — exclusions the whole team needs (`vendor/`, `node_modules/`, build output) still belong in `.gitignore`. For a file that is already *tracked* and should differ locally, neither applies; that is `git update-index --skip-worktree`. Verify the pattern took effect — a typo is silently inert, and an empty `git status` alone does not say which file did the excluding:

```bash
printf 'ANALYSIS-scratch.md\n' >> .git/info/exclude
# -v prints source file, line and pattern, so an exclude hit is distinguishable
# from a .gitignore hit and from no match at all (exit 1):
git check-ignore -v ANALYSIS-scratch.md
# .git/info/exclude:7:ANALYSIS-scratch.md    ANALYSIS-scratch.md
```

## Bulk sed/rename across a worktree must not touch its `.git` FILE

A linked worktree's `.git` is a file holding a `gitdir:` pointer, not a directory — `--exclude-dir=.git` does NOT protect it, and a blind `sed -i` over `grep -rl` output rewrites the pointer and breaks the worktree (`fatal: not a git repository`). Exclude the path explicitly (`grep -rl --exclude=.git` or filter the file list) before any bulk edit.

## A long rebase needs a reference merge to resolve against

Replaying dozens of commits onto a moved base means meeting the same conflict
several times, each time in a different intermediate state, with nothing at the
end that says the result is right. Build the answer once, then resolve against
it:

Steps 1 and 4 run from the project root of a bare layout (drop the `-C .bare` in
a normal clone); steps 2 and 3 run in the branch worktree. `tests/test_advanced_git_recipes.sh`
executes all of it against a fixture, so the commands below are the ones that
are known to run.

```bash
# 1. Target state, in a throwaway worktree.
git -C .bare worktree add --detach /tmp/ref <branch>
git -C /tmp/ref merge --no-commit --no-ff origin/<base>   # resolve by hand, then
git -C /tmp/ref add -- <each path you resolved>           # unmerged paths block the commit
git -C /tmp/ref status --porcelain                        # nothing unexpected left?
git -C /tmp/ref commit -m REF
git -C /tmp/ref branch ref-target                         # pin it: /tmp is no home for the only ref

# 2. In the branch worktree: rebase, resolving each conflict from REF instead
#    of re-deciding it.
git checkout ref-target -- <conflicted-path>

# 3. The assertion that makes the detour worth it.
git diff --stat ref-target HEAD    # must print nothing

# 4. Afterwards, from the project root.
git -C <branch-worktree> worktree remove --force /tmp/ref
git -C <branch-worktree> branch -D ref-target
```

Stage by name, as the rule above says. `add -A` sweeps untracked files into REF
and step 3 then fails spuriously; `add -u` skips paths the resolution *creates*
(splitting a file, extracting a helper) and drops them silently — the commit
still succeeds because unmerged paths were staged, and REF is quietly wrong. The
`status --porcelain` line is what catches both.

`--force` on the removal because a resolution leaves `.orig` files behind and
`worktree remove` refuses an untracked-dirty worktree; everything worth keeping
is already in `ref-target`. Two statements, not `&&`, so the pin is deleted even
if the removal complains. A branch rather than a tag, because a *lightweight* tag
dies under a global `tag.gpgsign=true` with the unhelpful `fatal: no tag
message?`, and `git checkout ref-target -- <path>` accepts a branch name.

Step 3 is the point. It catches what conflict markers cannot: in one 35-commit
rebase it surfaced a duplicated `autoload-dev` block in `composer.json` that Git
had merged cleanly from two sides. Commits that come out empty are branch fixups
already contained in REF — `git rebase --skip` them. (`--autosquash` does not
help here: it only acts on commits whose messages start with `fixup!`/`squash!`.)

Two caveats. Resolving from REF puts final content into intermediate commits, so
individual commits are no longer independently green — acceptable when the
branch is reviewed as a whole or about to be fixup-folded, not when it must stay
bisectable.

And step 2 is the one sanctioned use of `git checkout <ref> -- <path>` against a
dirty tree (see the rule above), but only on a path **still carrying conflict
markers, before you edit it**: both sides then live in committed objects, so
nothing unrecoverable is overwritten. Once you have hand-written a resolution
into that file, the rule applies again in full — the checkout discards your edit
with no reflog entry and no way back.

## A merge resolved in favour of the branch silently reverts upstream work

When `Merge branch 'develop'` keeps the branch's version of a file, the upstream
changes it dropped disappear without a trace: from the *next* merge base that
revert looks like an intentional branch edit, so no later diff, rebase, or
review flags it. Observed cost — a merge discarded four files' worth of an
upstream "raise phpstan to level 1" commit, reinstating an
`(string)isset(...) !== ''` expression and an `empty()` test against an
`ObjectStorage` that is never true. Both survived a rebase, because the rebase
faithfully replayed the bad resolution.

The candidate set is what upstream changed **before** each merge — that is the
work that merge's resolution could have dropped. Two traps: deriving it from
what upstream changed *since* the merge (different files, so the check prints
unrelated names, or nothing at all and reads as an all-clear), and running it
once on a branch that merged the base more than once. `merge-base` of the *later*
merge's parents resolves to the earlier merge's upstream parent, so a single run
only covers the window between them and a drop from the first merge stays
invisible. Run it **per merge commit**:

```bash
# bash. Run before merging the branch back: once origin/<base> contains it the
# range is empty and the loop prints nothing, which reads as an all-clear.
merges=$(git rev-list --merges origin/<base>..<branch>)
[ -n "$merges" ] || echo "no merges in range — did the branch already land?"

for m in $merges; do
  [ "$(git rev-list --parents -n1 "$m" | wc -w)" -gt 3 ] \
    && echo "$m OCTOPUS: parents 3+ not checked"

  # Which parent is upstream? ^2 for a merge made ON the branch, ^1 for one
  # made the other way round. A sibling-branch merge has neither and is skipped
  # rather than reported as one false positive per file the sibling touched.
  if git merge-base --is-ancestor "$m^2" origin/<base>; then up=$m^2; base_side=$m^1
  elif git merge-base --is-ancestor "$m^1" origin/<base>; then up=$m^1; base_side=$m^2
  else echo "$m SKIP: neither parent is upstream (sibling merge)"; continue; fi

  BASE=$(git merge-base "$base_side" "$up")
  git diff -z --name-only "$BASE" "$up" | while IFS= read -r -d '' f; do
    git diff --quiet origin/<base> <branch> -- "$f" || echo "$m DIFFERS: $f"
  done
done
```

Then redo the resolution for each file the check named, with **that merge's own
sides** — not today's tips, which is a second way to manufacture false
positives: anything upstream changed after the merge then shows up as dropped
work.

```bash
m=<the merge the check named>; f=<the path it named>
BASE=$(git merge-base "$m^1" "$m^2")
git show "$BASE:$f" > /tmp/base
git show "$m^1:$f"  > /tmp/ours
git show "$m^2:$f"  > /tmp/theirs
git show "$m:$f"    > /tmp/result
git merge-file -p --diff3 /tmp/ours /tmp/base /tmp/theirs > /tmp/merged
diff -u /tmp/result /tmp/merged
```

Read that diff rather than trusting it wholesale: it also contains conflict
markers where both sides moved. What you are looking for is upstream hunks
present in `/tmp/merged` and absent from the merge result.

## Keep a revert commit pure when the same file also needs a follow-up edit

A revert that arrives with an improvement — put the class back *and* document it,
restore the default *and* add the test that pins it — is two commits, and the
first one has to stay a revert a reviewer can check by reading `git revert`'s own
output. Editing the file before committing merges the two and destroys that
property: the diff of commit one is then a rename plus an unexplained hunk.

`git checkout --` is the wrong way back, because it restores the last *committed*
state and would discard the edit you are about to want. Keep a copy instead:

```bash
git revert -m 1 --no-commit "$MERGE_SHA"
git status --porcelain                 # expect exactly the paths you meant
# ... make the follow-up edit, then set it aside and restore the pristine file:
cp path/to/File.php /tmp/File.documented
git show "HEAD:$OLD_PATH" > path/to/File.php
diff <(git show "HEAD:$OLD_PATH") path/to/File.php && echo IDENTICAL
git add path/to/File.php "$OLD_PATH" && git commit -S --signoff -F revert-msg.txt
cp /tmp/File.documented path/to/File.php    # commit two carries the edit
```

`$OLD_PATH` has to be staged alongside the new one or the rename is recorded as
an add plus a stray deletion. `git show HEAD:<old path>` is what makes this work
for a file that has moved: after `revert --no-commit` the old path still exists
in `HEAD`, so its committed content is reachable even though the working tree no
longer has it there.

The scratch copy goes outside the worktree. A `.bak` beside the code is one
`git add -A` away from being committed, which is the failure this section exists
to avoid.

## Verify a branch split by blob identity, not by reading the diffs

Splitting one branch into several — per topic, per reviewer, to unblock the
easy parts — invites silently leaving something behind. Reading the diffs cannot
prove coverage; comparing object ids can:

```bash
# bash (read -d is not POSIX). -z survives paths with spaces or newlines.
branches="<branch-1> <branch-2>"    # every split branch

# Run the whole check in a subshell so the guard's exit does not close your
# shell when this is pasted in.
(
# Not optional: an unresolvable name makes every lookup ABSENT, which equals the
# umbrella's ABSENT on a deleted path and reports a genuine miss as carried.
for b in $branches; do
  git rev-parse --verify -q "$b^{commit}" >/dev/null || { echo "no such branch: $b" >&2; exit 1; }
done

# The `|| ABSENT` is what makes deletions work: git rev-parse ECHOES its
# argument on failure, and two different echoes never compare equal, so without
# the sentinel a path deleted by the umbrella is always reported NOT CARRIED.
# --verify -q keeps the accompanying `fatal:` lines off stderr.
git diff -z --name-only origin/<base> <umbrella> | while IFS= read -r -d '' f; do
  u=$(git rev-parse --verify -q "<umbrella>:$f") || u=ABSENT
  carried=""
  for b in $branches; do
    v=$(git rev-parse --verify -q "$b:$f") || v=ABSENT
    [ "$v" = "$u" ] && carried=$b && break
  done
  [ -n "$carried" ] || echo "NOT CARRIED: $f"
done
)
```

The guard is what keeps a typo from masking a miss. One wrong name is enough:
its lookups all return `ABSENT`, which matches the umbrella's `ABSENT` on a
deleted path, so that path is credited as carried and disappears from the
output.

Everything the loop prints is either a deliberate drop — name each one — or an
oversight. Files that several branches change by hunk (`composer.json`, a CI
config) never match a single branch and need the complementary check: parse both
sides and compare key by key, e.g. `yaml.safe_load` per job for a CI file, so
"no job lost" is a computed result rather than an impression.
