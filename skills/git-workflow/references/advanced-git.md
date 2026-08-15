# Advanced Git Operations

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

Two recurring failure modes:

- **Reporting a stale value as fact.** Reading `"^0.13"` from an un-fetched
  worktree and stating "the constraint needs bumping" — when current `main` already
  says `"^0.17 || ^0.18 || ^0.19"`. Verify against `origin/main` before writing the
  claim into a design or PR.
- **A subagent silently reads a stale checkout.** When you dispatch an agent to
  "read the source" for a decision, name the ref/worktree it must read, and
  re-verify its structural claims (config keys, signatures) against the current
  tree before building on them — half a report can come from an outdated path.

Confirm the constructor/signature at the **resolved** dependency version (the one
installed in `vendor`/`.Build`), not the library's `main` branch — they drift
(e.g. a value object gaining a required constructor arg between minor releases).

### Bare-Repo Layouts

With the bare-clone convention (`project/.bare` + one directory per branch),
relative `worktree add` paths resolve from *inside* `.bare` — see the detailed
path-resolution rules and recovery steps in the bare-repo section below.

Before nesting a `.bare` into an existing directory, check whether it already
holds a **plain clone** — mixing the two layouts leaves a repo checkout *and* a
worktree side by side in one directory.

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

Skipping this once meant building an ADR off a *different* repo's config until a
version/branch mismatch exposed it.

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

### Repository Maintenance

```bash
# Garbage collection
git gc

# Aggressive gc
git gc --aggressive

# Prune unreachable objects
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

# Recover stash
git fsck --unreachable | grep commit | cut -d' ' -f3 | \
  xargs git log --merges --no-walk --grep=WIP
```

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
