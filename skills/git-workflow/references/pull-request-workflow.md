# Pull Request Workflow

Covers the PR lifecycle for Netresearch repos: branch and tooling checks
before opening a PR, commit discipline, merge strategies, review-thread
resolution, and the merge gate. See `references/commit-conventions.md` for
commit message formatting.

## Check the Default Branch Before Operating

Not every repo uses `main` — older repos often use `master`, and some use
`develop` or `trunk`. Before pushing, opening a PR, or scripting across many
repos, resolve the actual default branch instead of assuming:

```bash
gh repo view OWNER/REPO --json defaultBranchRef --jq '.defaultBranchRef.name'
```

Assuming the wrong name silently pushes to (or creates) the wrong branch, or
targets a PR at a branch that isn't the integration branch.

## After a Detour to Another PR, Switch Back — and Verify

Working two PRs at once, a fix for PR B often means checking out B's branch
mid-task. Nothing switches you back afterwards, and the next edits land on B
while you believe you are on A. Because `git status` looks normal — modified
tracked files, no conflict — the mistake surfaces only later, e.g. when a value
you "already added" reads back as absent.

Re-assert the branch before resuming edits, and again before staging:

```bash
git branch --show-current    # cheap; run it after ANY cross-PR detour
```

If edits did land on the wrong branch, move them rather than redoing them:

```bash
git stash push -m "misplaced work" -- <paths>   # path-scoped: leaves the branch's own work alone
git checkout <intended-branch>
git stash pop
```

Prefer a separate worktree per PR (`references/advanced-git.md`) when the two
are worked in parallel — then no checkout is shared and the detour cannot
misplace anything.

## Prefer the `gh` CLI / GitHub MCP Over Raw API or Web UI

For GitHub operations (PRs, issues, reviews, releases), reach for `gh` or the
GitHub MCP tools before hand-rolling `curl`/REST calls or clicking through the
web UI: consistent authentication, structured `--json` output, and clearer
errors. Drop to raw `gh api` only for endpoints the porcelain commands don't
cover yet.

## Atomic Commits (Default — No Squash Unless Asked)

**The project default is atomic commits preserved end-to-end.** Squash is destructive: it loses GPG signatures, collapses bisection granularity, and destroys narrative. Never squash unless the user asks for it in this task.

### What "atomic" means

- One commit = one self-contained logical change
- Each commit builds and passes tests independently
- No "WIP", "fixup", or "oops" commits in final history — rebase them away before merge
- Mixed changes get split (`git add -p`, `git commit --fixup`, `git rebase --autosquash`)

### Preferred merge strategies (in order)

1. **Rebase + merge commit** (`gh pr merge --merge` after `git rebase origin/main`): linear feature history with an explicit merge point. Preserves signatures. This is the default for Netresearch repos.
2. **Fast-forward merge** (local `git merge --ff-only`): when signed commits are required AND only rebase is allowed (see "Signed Commits with Rebase Merge" below).
3. **Squash**: only when the user explicitly asks.

### If you catch yourself typing `--squash`

Stop. Re-read the task. Did the user say "squash"? If not, use `--merge` or `--rebase` (with the signed-commits caveat). The correction "no squash! atomic commits!" is a repeat interruption — prevent it by defaulting to merge-commit.

## Review Thread Resolution (SHA Citation Required)

**Never reply with "Addressed" or "Fixed" without citing the resolving commit SHA.** Review threads are resolved on GitHub's side, not by agent assertion.

### Correct reply pattern

```bash
# After pushing the fix
SHA=$(git rev-parse HEAD)

gh api graphql -f query='
  mutation($body: String!, $id: ID!) {
    addPullRequestReviewThreadReply(input: {body: $body, pullRequestReviewThreadId: $id}) {
      comment { id }
    }
  }' \
  -f body="Fixed in ${SHA:0:7} — <1-sentence explanation of what changed and why>." \
  -f id="PRRT_xxx"

# Then resolve the thread
gh api graphql -f query='mutation { resolveReviewThread(input: {threadId: "PRRT_xxx"}) { thread { isResolved } } }'
```

### Refusing the lazy pattern

These replies are banned:
- `Addressed` (no SHA, no explanation)
- `Fixed — merged` (merged what? where?)
- `Done` (done how?)
- `Good point, updated` (updated what, in which commit?)

Every resolving reply must include: commit SHA (7+ chars), one sentence of what changed, one sentence of why if not obvious from the diff.

### Verifying AI-reviewer claims before acting

AI reviewers (GitHub Copilot, Gemini Code Assist, SonarCloud) mix correct findings with confident hallucinations. Before applying **or** declining a review comment, verify its load-bearing factual claim against an authoritative source — the framework/library code, official docs, or a quick local probe — not the reviewer's assertion alone.

- **Applying blindly** ships wrong code (e.g. an edit based on a false API claim, which may also fail your own linter/type-checker).
- **Declining blindly** dismisses real bugs — the same reviewer is often right about the next comment.

Reply citing the evidence either way. When you applied a change, the reply must still carry the commit SHA and the what/why required above (e.g. `Verified against <source>: <fact> — applied in <SHA>, which …`); when you declined, state the source and fact (e.g. `Verified against <source>: <fact> — declining.`). When the suggestion is a code change, run the project's checks (lint, types, tests) on it before resolving, so the reply cites a green result rather than a guess.

**Intentional SAST findings on test code: dismiss the alert, don't contort the test.** A static-analysis finding (SonarCloud, CodeQL / GitHub Advanced Security) that fires on a *deliberate* test input — an SSRF test hitting `169.254.169.254`, a clear-text `http://…` URL a denial test asserts on, a synthetic secret fixture — is a false positive against the test's intent. Rewriting the test to satisfy the analyzer weakens the very case it exists to prove. Instead **dismiss the alert at its source**, which also clears the blocking `github-advanced-security` review thread that a plain reply cannot resolve:

```bash
# Find the alert number for the flagged file/rule, then dismiss:
gh api repos/$R/code-scanning/alerts --jq '.[]? | {number, rule: .rule.id, path: .most_recent_instance.location.path}'
gh api repos/$R/code-scanning/alerts/$N -X PATCH \
  -f state=dismissed -f dismissed_reason='used in tests' \
  -f dismissed_comment='Intentional test input — <one line why>.'
```

`dismissed_reason` is one of `false positive` / `won't fix` / `used in tests`; use `used in tests` for deliberate test inputs. SonarCloud has the equivalent "Won't fix / Safe" transition in its UI (auto-analysis ignores `sonar.issue.ignore.*`, so mark it there, not in config). Reply to the thread citing the dismissal, then resolve it.

### AI-authored commits on the branch are untrusted

Distinct from a review *comment*: Copilot **Autofix**, Gemini "apply suggestion", and similar bot-authored **commits already pushed onto the PR branch** are patches, not settled work — they can carry real bugs, and they arrive looking done. In one `/pr-finish` run the autofix commits had (a) deleted a variable's initialization while keeping the line that reads it — an `UnboundLocalError` on every non-account query — and (b) added an unbounded `while True` pagination loop that later OOM-crashed the machine (see the *Cap memory when the fix activates or relies on a loop* bullet under *Fixing the failure*). Treat every bot commit like an untrusted patch:

- **Read its net diff against your last human commit**, not just the headline — `git diff <your-last-sha> HEAD -- <file>` (or `git show <bot-commit-sha>` for one specific commit). The fix a bot "applied" often removes or rewrites more than the comment implied.
- **Squash them into the atomic feature commit and re-run the FULL suite** — not only the check that was failing. A green "the failing check now passes" does not clear a bug the bot introduced *elsewhere*; only the whole suite does (this is the *Verify the activated code path* rule — a bot fix can make dead code live).
- Their missing `Signed-off-by`/signature is also why the DCO / signed-commits gate fails; squashing under your own signed, signed-off commit fixes correctness and the gate in one step.

### Minimizing bot-review rounds (collapse the ping-pong)

On a repo with an incremental AI-reviewer ruleset (`copilot_code_review`, Gemini), **every push re-triggers a fresh required review round** that re-BLOCKs the PR — and AI reviewers surface *semantic* nits a linter never catches (heading structure, code-wrap conventions, cross-reference/notation consistency). Pushing one fix per comment turns this into 3+ rounds of request → wait (minutes each) → re-block. Collapse it:

- **Semantic self-review before the first push.** Lint/markdownlint passing is not enough — re-read the diff for the convention nits an AI reviewer will flag, and fix them pre-emptively.
- **Batch all review fixes into ONE push**, not per-comment. Each push restarts the round; one push = one new round.
- **Pre-empt the recurring code-quality nit classes** — AI reviewers reliably re-flag the same gaps, so fixing them *before* the first push removes whole rounds. On new code, self-check: **bound every paginate-until-metadata loop** with a hard cap that raises (never trust the response to signal "last page"); **coerce external-payload fields to the expected type** before downstream use (a field documented as an object can arrive as a string — guarantee the shape, don't assume it); **availability probes treat 5xx and 401/403 as "unavailable," not only 404** (else an outage/auth failure selects the backend and dies on the real call); **add a test for every new code path** (an untested new path is both a coverage nit and where the worst bugs hide).

Expect 2–3 rounds even so; the loop *mechanics* (wait for the bot to review the latest head SHA, never merge over an in-flight re-review — see *Merge Gate*) still apply. This tactic reduces the **number** of rounds, not how you survive each one.

### Verifying thread state from GitHub, not memory

Before declaring a PR review-complete, re-fetch thread state from GitHub. Never trust your own belief about what you resolved:

```bash
gh api graphql -f query='
  query($owner: String!, $repo: String!, $pr: Int!) {
    repository(owner: $owner, name: $repo) {
      pullRequest(number: $pr) {
        reviewThreads(first: 100) {
          nodes { id isResolved comments(first: 1) { nodes { body author { login } } } }
        }
      }
    }
  }' -f owner=OWNER -f repo=REPO -F pr=NUMBER \
  | jq '.data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved == false) | {id, first_comment: .comments.nodes[0].body[:80]}'
```

If that returns any rows, the PR is not merge-ready.

### Wait for the async re-review before trusting `unresolved == 0`

`unresolved == 0` is **not** merge-ready if you sampled it right after a push.
GitHub Copilot (and Gemini, and similar bot reviewers) re-review the PR
**asynchronously** — typically 1–2 minutes after each push — and each round can
post entirely **new** review threads against the fresh head. Reasoning about
merge-readiness on a zero count that predates the bot's re-review produces a
premature "threads clear" call; the bot then lands more valid findings a minute
later. In one session, sampling too early gave a false all-clear **twice**, and
the bot posted five more legitimate findings on each following round.

So don't check thread count first — **check that the bot has actually reviewed
the current head SHA first**, then re-check threads. Poll until a bot review
whose `commit_id` equals the PR head has landed:

```bash
HEAD=$(gh pr view "$PR" --repo "$R" --json headRefOid --jq .headRefOid)
# A Copilot review keyed to the current head must exist before you trust the count.
SEEN=$(gh api "repos/$R/pulls/$PR/reviews" \
  --jq "[.[]? | select(.user?.login? // \"\" | test(\"copilot\";\"i\")) | select((.commit_id? // \"\")==\"$HEAD\")] | length")
[ "${SEEN:-0}" -ge 1 ] || { echo "bot has not re-reviewed head $HEAD yet — keep polling"; }
```

Only once `SEEN >= 1` is the unresolved-threads query above meaningful. This is
the same "review the latest head SHA" gate the [Merge-Gate Watcher](merge-gate-watcher.md)
enforces — apply it here too, before ever declaring the review done.

## Merge Strategies

### Merge Commit

```bash
# Creates a merge commit, preserves all history
git checkout main
git merge --no-ff feature/my-feature

# Result:
#   * Merge branch 'feature/my-feature'
#   |\
#   | * feat: add feature part 2
#   | * feat: add feature part 1
#   |/
#   * Previous main commit
```

**Use when:**
- Want to preserve complete branch history
- Complex features with meaningful intermediate commits
- Audit trail required

### Squash and Merge

```bash
# Combines all commits into one
git checkout main
git merge --squash feature/my-feature
git commit -m "feat: complete feature implementation"

# Result:
#   * feat: complete feature implementation
#   * Previous main commit
```

**Use when:**
- Feature branch has messy history
- WIP commits, fixups, "oops" commits
- Want clean linear history

### Rebase and Merge

```bash
# Replays commits on top of main
git checkout feature/my-feature
git rebase main
git checkout main
git merge --ff-only feature/my-feature

# Result:
#   * feat: add feature part 2
#   * feat: add feature part 1
#   * Previous main commit
```

**Use when:**
- Clean commit history in feature branch
- Each commit is meaningful and tested
- Want linear history without merge commits

### Comparison

| Strategy | History | Complexity | Traceability |
|----------|---------|------------|--------------|
| Merge | Preserved | High | High |
| Squash | Combined | Low | Medium |
| Rebase | Linear | Low | Medium |

## Merging Divergent Upstream History (Forks)

Catching a fork up with its upstream looks like a merge-strategy question. It is
mostly a **scope** question, and four traps sit between the two.

### "Merge" is a constraint on history rewriting — not an instruction to import everything

When a maintainer rejects a rebase because *"rebasing would break our releases"*
and says **"we need to merge"**, the load-bearing word is not *merge* — it is
*don't rewrite the SHAs our releases point at*. Merge is one mechanism that
satisfies that; **cherry-pick satisfies it too**, and so does doing nothing.

Establish the **net delta before choosing the mechanism**, and say it out loud:

```bash
UPSTREAM=hashicorp/some-project      # the repo you forked
FORK=your-org/some-project           # your fork

git fetch upstream
git log --oneline origin/main..upstream/main | wc -l   # what we would gain
gh api "repos/$UPSTREAM/compare/main...${FORK%%/*}:main" --jq '{ahead: .ahead_by, behind: .behind_by}'
# Where the conflict surface actually lives — often one directory dominates
gh api "repos/$UPSTREAM/compare/main...${FORK%%/*}:main?per_page=100" \
  --jq '[.files[].filename | split("/")[0]] | group_by(.) | map({dir: .[0], n: length}) | sort_by(-.n) | .[0:5]'
```

For *what we add*, prefer `git cherry` over `git log`: it compares by **patch-id**,
so a change of yours that upstream already carries under a different SHA is
correctly reported as already-there. `git log upstream/main..origin/main` counts it
as yours and overstates the delta.

```bash
git cherry -v upstream/main origin/main | grep -c '^+'   # genuinely ours
git cherry -v upstream/main origin/main | grep '^-'      # already upstream, other SHA
```

This is not hypothetical: on the fork below, `git log` reported 27 commits while
`git cherry` reported 26 — the difference being the fork's own **re-authored port**
of an upstream fix, which `git cherry` matched to the upstream original despite a
different SHA, author, *and* commit message.

If the valuable delta is a handful of commits — or one typo fix — a merge of the
full history buys you every conflict and every unsigned commit in that history to
deliver it. Cherry-pick the delta instead; the SHA-preservation constraint is met
either way.

**Real case:** a fork 22 ahead / 11 behind an **archived** upstream. The merge
produced 548 conflicts and 11 DCO-breaking commits; the entire net gain was a
two-line typo fix (the other 10 commits were vendor churn, the upstream's own
release CI, and dependency bumps the fork had already surpassed). The delta had
been measured *before* the merge and the merge was run anyway. The maintainer's
correction — *"if the typo is the only change, pull in the typo, nothing more"* —
was the whole job.

**Tell:** you are resolving conflicts in files your fork deliberately diverged on
(vendor trees, CI, templates) to obtain something you could name in one sentence.

### Resolve the repo's allowed merge methods *before* authoring a merge commit

A repository that permits **only rebase-merge** cannot land a merge commit: `--rebase`
replays the branch and **flattens the merge**, rewriting exactly the SHAs the merge
existed to preserve. Discovering this at merge time means the work was mis-shaped from
the start.

```bash
gh api "repos/$OWNER/$REPO" --jq '{allow_merge_commit, allow_rebase_merge, allow_squash_merge}'
```

Run it **before** you build the merge, not at step "merge". If merge commits are
disabled but a true merge is required, the options are: enable `allow_merge_commit`
(a repo-policy change affecting every future PR), a local fast-forward push (see
*Signed Commits with Rebase Merge* — `main` can fast-forward to the merge commit
when its first parent is `main`'s head), or a different mechanism entirely.

### Conflicts are not the whole merge — check clean ADDs under a deleted path

`git merge` only reports conflicts for paths **both sides touched**. Files the other
side **added** that your side never had merge **silently, with no conflict** — so if
your fork *deleted* a directory upstream still maintains, resolving every conflict
still leaves you re-importing it.

```bash
# 545 conflicts resolved... and 252 files quietly staged as clean additions
git status --porcelain | grep '^A' | grep ' vendor/' | wc -l
git diff --cached --name-only -- vendor | wc -l
```

**Real case:** a fork that had run `chore: unvendor` merged an upstream that still
vendors. 545 paths conflicted `DU` (deleted by us / modified by them) — and **252
more merged cleanly as additions**, because upstream's vendor upgrade had *added*
files the fork never carried. Resolving the conflicts alone would have silently
re-vendored the project and reverted the unvendoring, with a green merge.

After any merge involving a path one side removed:

```bash
git rm -rfq --ignore-unmatch -- <path>   # plain `git rm` refuses when the index has staged changes
git ls-files -- <path> | wc -l           # must be 0
```

### DCO and third-party history are structurally incompatible

A DCO check requires every commit to carry a `Signed-off-by` **matching its author**.
Upstream's commits carry none, and **you cannot sign off on someone else's authorship**
— sign-off is a declaration about work you have the right to submit. So *any* fork
merging *any* third-party history fails DCO by construction. This is not a mistake to
fix; it is a property of the operation.

Do **not** follow the DCO bot's own advice here. It suggests `git rebase HEAD~N --signoff`,
which rewrites the upstream commits and flattens the merge — destroying the ancestry the
merge existed to record, and forging sign-offs on other people's commits.

Real options, in order:

1. **Don't merge the history — port the change.** Cherry-pick, then re-author under your
   own sign-off, crediting the original in the message. `git cherry-pick -x` keeps the
   original author and therefore still fails DCO; `git commit --amend --reset-author -S --signoff`
   makes it your commit, which is honest for a two-line port and passes the gate:

   ```bash
   git cherry-pick -x <upstream-sha>
   git commit --amend --reset-author -S --signoff   # message credits upstream <sha> + author
   ```
2. **Check whether DCO is actually required** before treating it as a blocker —
   `gh api repos/$R/branches/$BASE/protection --jq '.required_status_checks.contexts'`.
   A red-but-not-required DCO is a policy call, not a gate.
3. **Third-party remediation** via `.github/dco.yml` (`allowRemediationCommits: {thirdParty: true}`)
   — a legal declaration on someone else's work. A human decides that, never an agent.

## Automated Checks

### GitHub Actions for PRs

```yaml
# .github/workflows/pr-checks.yml
name: PR Checks

on:
  pull_request:
    branches: [main, develop]

jobs:
  lint:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: '20'
      - run: npm ci
      - run: npm run lint

  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: '20'
      - run: npm ci
      - run: npm test -- --coverage

  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: '20'
      - run: npm ci
      - run: npm run build

  pr-size:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
      - name: Check PR size
        run: |
          ADDITIONS=$(gh pr view ${{ github.event.pull_request.number }} --json additions -q '.additions')
          if [ "$ADDITIONS" -gt 1000 ]; then
            echo "::warning::Large PR detected ($ADDITIONS lines). Consider splitting."
          fi
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
```

### Required Status Checks

```yaml
# Branch protection settings
required_status_checks:
  strict: true
  contexts:
    - lint
    - test
    - build
    - security-scan
```

### CODEOWNERS

```bash
# .github/CODEOWNERS

# Default owners for everything
* @default-team

# Frontend owners
/src/components/ @frontend-team
/src/styles/ @frontend-team @design-team

# Backend owners
/src/api/ @backend-team
/src/database/ @backend-team @dba-team

# DevOps owners
/.github/ @devops-team
/docker/ @devops-team
/terraform/ @devops-team

# Documentation
/docs/ @docs-team
*.md @docs-team

# Security-sensitive files
/src/auth/ @security-team @backend-team
/src/crypto/ @security-team
```

## PR Lifecycle

### States

```
Draft → Ready for Review → Changes Requested → Approved → Merged
         ↑_____________________|
```

### Commands

```bash
# Check PR status
gh pr status
gh pr view 123

# Request review
gh pr edit 123 --add-reviewer "@reviewer1,@reviewer2"

# Mark ready for review
gh pr ready 123

# Convert to draft
gh pr ready 123 --undo

# Approve PR
gh pr review 123 --approve

# Request changes
gh pr review 123 --request-changes --body "Please fix X"

# Merge PR
gh pr merge 123 --squash --delete-branch

# Close without merging
gh pr close 123
```

### Handling Stale PRs

```yaml
# .github/workflows/stale.yml
name: Mark Stale PRs

on:
  schedule:
    - cron: '0 0 * * *'  # Daily

jobs:
  stale:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/stale@v9
        with:
          repo-token: ${{ secrets.GITHUB_TOKEN }}
          stale-pr-message: 'This PR has been inactive for 14 days. Please update or close.'
          days-before-stale: 14
          days-before-close: 7
          stale-pr-label: 'stale'
```

## Conflict Resolution

### Before Merging

```bash
# Update feature branch with latest main
git checkout feature/my-feature
git fetch origin
git rebase origin/main

# If conflicts occur
# 1. Edit conflicting files
# 2. Stage resolved files
git add <resolved-file>
# 3. Continue rebase
git rebase --continue

# Force push (only on feature branches!)
git push --force-with-lease
```

### Merge Conflicts in PR

```bash
# Option 1: Rebase (preferred for clean history)
git checkout feature/my-feature
git fetch origin
git rebase origin/main
# Resolve conflicts
git push --force-with-lease

# Option 2: Merge main into feature
git checkout feature/my-feature
git merge origin/main
# Resolve conflicts
git commit
git push
```

### Updating a PR branch without a local clone — `gh pr update-branch --rebase`

To bring a **conflict-free** PR up to date with its base without checking it out, rebase its head branch remotely:

```bash
gh pr update-branch <number> --repo <owner>/<repo> --rebase
```

Unlike the plain `gh pr update-branch` (which *merges* base into the branch and leaves a merge commit), `--rebase` keeps linear history — compatible with rebase-only repos. It only succeeds cleanly when the PR has no conflicts (`mergeable: MERGEABLE`); on conflicts, fall back to a local rebase. It **force-updates** the branch, so it re-triggers CI and can reset review approvals — only worth it when staleness actually blocks the merge. Works well for a bulk "rebase all my open PRs that need it" sweep (`gh search prs --author=@me --state=open` → loop).

**Judge "behind" correctly — don't trust `mergeStateStatus` alone.** GitHub only reports `mergeStateStatus: BEHIND` when the base enforces *"require branches to be up to date before merging."* Without that rule a PR many commits behind base still shows `CLEAN`/`BLOCKED`, never `BEHIND`. To know how far behind a PR actually is, ask the compare API:

```bash
gh api "repos/<owner>/<repo>/compare/<base>...<headSha>" --jq '{behind: .behind_by, ahead: .ahead_by}'
```

A conflict-free PR that is merely behind (no `BEHIND` flag, `mergeable: MERGEABLE`) does **not** need a rebase to merge — rebasing it is optional churn that re-runs CI. Reserve it for PRs the base blocks on staleness, or ones so far behind they should be re-validated against current base.

### Commit Before Rebase — Correct Push Ordering

When you have uncommitted local changes that need to be pushed, the order matters:

```bash
# ✅ Correct — commit first, then sync, then push
git add <files>
git commit -m "message"
git fetch origin
git rebase origin/<branch>
git push

# ❌ Wrong — rebase aborts with "please commit your changes or stash them"
git fetch origin
git rebase origin/<branch>   # aborts with error if working tree is dirty
git add <files>
git commit -m "message"
git push                     # rejected as non-fast-forward
```

The "fetch+rebase before push" rule means **before pushing**, not before committing. `git rebase` requires a clean working tree — it aborts with an error when uncommitted changes are present, leaving the branch behind the remote. The subsequent push is then rejected as non-fast-forward, requiring an extra fix cycle.

### Verify a push actually landed (never grep push output)

A push can silently fail to land while a piped command swallows the signal — `git push … | grep 'new branch'` or `… | tail` can hide a non-zero exit (wrong remote/auth, or an *empty* commit because a path was silently excluded by `.gitignore`). Confirm the remote ref moved, by SHA — don't infer success from push output:

```bash
git push -u origin "$BR"
REMOTE_SHA=$(git ls-remote origin refs/heads/"$BR" | cut -f1)   # no fetch, no fatal if branch absent
[ "$(git rev-parse HEAD)" = "$REMOTE_SHA" ] && echo "landed" || echo "DID NOT LAND"
```

Likewise verify staging of any path that might be gitignored with `git status --short` before committing — an empty commit pushes "successfully" yet changes nothing.

The same trap applies to **every command whose exit code gates the next step**, not
just `git push`: in POSIX shells a pipeline's status is that of its **last** command
(`tail`, `grep`) unless `set -o pipefail` is active — and even with pipefail, a
trailing `grep` that matches nothing fails a *green* build. Real case:
`docker build … 2>&1 | tail -2 && echo OK` printed `OK` for a **failed** build, and
the broken branch was pushed before anyone noticed. Gate on the command's own exit
code; keep log inspection out of the gate:

```bash
docker build . > build.log 2>&1
rc=$?
tail -20 build.log            # inspection only — never part of the gate
[ "$rc" -eq 0 ] || exit 1
```

### `--force-with-lease` Rejected with "stale info"

On PRs that bots touch (auto-approve, Renovate/Dependabot, a CI step that pushes), `git push --force-with-lease` can be rejected with `stale info` even when your local work is correct: a bot updated the remote branch since your last fetch, so the lease's expected ref (your `origin/<branch>` tracking ref) no longer matches and the push aborts. This is the safety check working — don't escalate to plain `--force`.

Fetch, see what arrived, then push — the lease now matches the ref you just fetched:

```bash
BR=feature/my-feature
git fetch origin "$BR"
git log HEAD..origin/"$BR"               # what the bot pushed — safe to discard?
git push --force-with-lease origin "$BR" # lease compares against the fetched tracking ref
```

If a bot keeps pushing inside the fetch→push window so the plain lease never matches, pin it to the head you just inspected. This pins, not skips, the check — it accepts exactly that SHA, so only run it right after the `git log` above confirms those commits are safe to discard:

```bash
git push --force-with-lease="$BR:$(git rev-parse origin/"$BR")" origin "$BR"
```

### Complex Conflicts

```bash
# Use a merge tool
git mergetool

# Or use specific tool
git mergetool --tool=vscode
git mergetool --tool=meld

# Configure default tool
git config --global merge.tool vscode
git config --global mergetool.vscode.cmd 'code --wait $MERGED'
```

## PR Analytics

### Metrics to Track

1. **PR Size**: Average lines changed
2. **Review Time**: Time from creation to first review
3. **Time to Merge**: Creation to merge
4. **Review Rounds**: Number of change requests
5. **Throughput**: PRs merged per week

### GitHub Insights

```bash
# List PR stats
gh pr list --state merged --json number,title,createdAt,mergedAt,additions,deletions

# PR age analysis
gh pr list --state open --json number,createdAt | jq 'map({number, age: (now - (.createdAt | fromdateiso8601)) / 86400})'
```

## Review Thread Management

### Replying to Review Threads

When addressing review feedback, reply directly to the thread (not a new comment):

```bash
# Find the thread ID for a comment
gh api repos/OWNER/REPO/pulls/NUMBER/comments \
  --jq '.[] | {id, node_id, body}'

# Reply to a review thread via GraphQL
gh api graphql -f query='
  mutation($body: String!, $threadId: ID!) {
    addPullRequestReviewThreadReply(input: {
      body: $body,
      pullRequestReviewThreadId: $threadId
    }) {
      comment { id }
    }
  }' \
  -f body="Fixed in commit abc123" \
  -f threadId="PRRT_xxxxx"
```

### Resolving Review Threads

After addressing feedback and pushing fixes:

```bash
# Resolve a review thread
gh api graphql -f query='
  mutation($threadId: ID!) {
    resolveReviewThread(input: {threadId: $threadId}) {
      thread { isResolved }
    }
  }' \
  -f threadId="PRRT_xxxxx"

# List unresolved threads
gh api graphql -f query='
  query($owner: String!, $repo: String!, $pr: Int!) {
    repository(owner: $owner, name: $repo) {
      pullRequest(number: $pr) {
        reviewThreads(first: 50) {
          nodes {
            id
            isResolved
            comments(first: 1) {
              nodes { body }
            }
          }
        }
      }
    }
  }' -f owner=OWNER -f repo=REPO -F pr=NUMBER
```

### Handling Many Review Threads (Pagination)

**Critical:** GitHub GraphQL API has a limit of 100 items per page. For PRs with many
review comments (e.g., 127+ threads from automated reviewers), you MUST use pagination:

```bash
# Fetch ONE page of up to 100 threads; repeat with the returned endCursor
# until hasNextPage is false to cover all threads
gh api graphql -f query='
  query($owner: String!, $repo: String!, $pr: Int!, $cursor: String) {
    repository(owner: $owner, name: $repo) {
      pullRequest(number: $pr) {
        reviewThreads(first: 100, after: $cursor) {
          pageInfo {
            hasNextPage
            endCursor
          }
          nodes {
            id
            isResolved
            comments(first: 1) {
              nodes { body path }
            }
          }
        }
      }
    }
  }' -f owner=OWNER -f repo=REPO -F pr=NUMBER

# Loop until pageInfo.hasNextPage is false, passing each endCursor:
# -f cursor="Y3Vyc29yOnYyOpHOABCD..."
```

**Real-world lesson (PR #575):** Automated reviewers can generate 100+ comment threads.
Without pagination, only the first 100 threads are returned, leaving others unaddressed.

## Diagnosing CI Failures (Annotations First)

> Failure first-step, not pre-merge gate. The Merge Gate below uses `annotations_count` as a *warnings present?* signal after success. This section is the inverse: when a workflow has *failed* and you don't yet know why, read the annotation text **first**, before any other diagnostic action.

### Anti-pattern

When a GitHub Actions run fails — especially with `startup_failure`, "no jobs ran", "config invalid", or any failure where the PR summary view shows just a red X with no detail — do **not**:

- Speculate about transient infra issues
- Blame upstream commits or reusable-workflow regressions
- Diff the workflow YAML against the last known good revision
- Re-run the workflow hoping it passes

…before reading the check-runs annotations. The literal validator error is almost always sitting there in one line. Annotations are **invisible in the PR summary view** — they're only rendered in the Actions UI under each job's "Annotations" panel, easy to miss.

### Recipe

```bash
SHA=$(git rev-parse HEAD)  # or the failing commit SHA

# 1. Find every check run on that commit that has annotations
#    {owner}/{repo} are gh api placeholders — auto-resolved from cwd or $GH_REPO
gh api "repos/{owner}/{repo}/commits/$SHA/check-runs" --paginate \
  --jq '.check_runs[] | select(.output?.annotations_count? // 0 > 0) | "\(.id)\t\(.name)"' |
while IFS=$'\t' read -r run_id name; do
  echo "=== $name ==="
  # 2. Print the annotation text (level, file, line, message).
  #    --paginate guards against runs with > 100 annotations (rare for startup
  #    failures, common for linters like reviewdog).
  gh api "repos/{owner}/{repo}/check-runs/$run_id/annotations" --paginate \
    --jq '.[] | "[\(.annotation_level)] \(.path):\(.start_line) \(.message)"'
  echo ""
done
```

Drop this into the troubleshooting flow as **step 0**. If the annotations are empty, *then* fall back to logs (`gh run view RUN_ID --log-failed`) and YAML diffs.

### Real-world example

A reusable-workflow caller failed with `startup_failure` and zero jobs. Multiple turns were spent blaming upstream `netresearch/typo3-ci-workflows@main` commits and even pinning to a known-good SHA as a workaround. The annotation said the actual cause in one line:

> Error calling workflow '...'. The nested job 'preflight' is requesting 'actions: read', but is only allowed 'actions: none'.

Fix: one-line `actions: read` add to the caller's `permissions:` block ([t3x-nr-passkeys-be@0533835](https://github.com/netresearch/t3x-nr-passkeys-be/commit/0533835)). Reading the annotations first would have collapsed a 6-step diagnostic loop into a 2-step fix.

### Fixing the failure: reproduce the *exact* job, gate the push on a read verify

Three traps when fixing a red CI job:

- **Reproduce the exact failing step, not a proxy.** A passing *local* `make test` / `phpunit` does not prove the failing CI job is fixed — the job may fail on a different step or matrix cell (e.g. a `php -l` lint sweep over `vendor/` on PHP 8.4/8.5, or a stricter runner version) that your proxy never runs. Read which job + step failed and run *that* command, on that version, before claiming the fix.
- **Make the push a separate step, gated on a verify you actually read.** Bundling verify-and-push in one `&&` block force-pushes before the result is seen — a run that printed `FAIL` still gets pushed. Capture the verify to a file, read it, and push only on a confirmed-clean result:

```bash
run_tests > /tmp/verify.log 2>&1; RC=$?
cat /tmp/verify.log; echo "rc=$RC"   # read the log + exit code first
[ "$RC" -eq 0 ] && git push || echo "STOP — tests failed, do not push"
```

- **Cap memory when the fix activates or relies on a loop.** A bug-fix can make previously-dead code *live* — and if the now-live path paginates or loops over an external (or mocked) response, an **unbounded** loop can exhaust RAM and OOM-crash the whole machine when you reproduce the test locally. (Real case: restoring a deleted variable unblocked a code path whose `while True` pagination loop then grew a MagicMock to >20 GB RSS and took down the VM.) Two defenses, apply both:
  - **Run the repro under a memory cap** so a runaway loop fails fast instead of freezing the box: `( ulimit -v 6000000; pytest tests/… )` (≈6 GB virtual). Do this whenever a loop's termination depends on code you just changed. `ulimit -v` is a Linux mechanism — it is ignored on macOS/Darwin, so there run the repro inside a container instead (`docker run --memory=6g …`) or use another runtime-level cap.
  - **Bound the loop itself** — `for _ in range(MAX_PAGES): … else: raise RuntimeError(...)` — rather than trusting the response's metadata (or a test mock) to signal the last page; and give the test a finite mock (`side_effect=[page1, page2]`), never a bare mock whose `.get()` is truthy forever.

### Relationship to the Merge Gate annotations check

| Stage | Question | Endpoint |
|-------|----------|----------|
| Failure diagnosis (this section) | "Why did the run fail?" | `/check-runs/{id}/annotations` (read messages) |
| Pre-merge gate (below) | "Are there warnings to clear before merging green CI?" | `/commits/{sha}/check-runs` (count > 0) |

Same endpoint family, different question — read the annotation text on failure, count it on success.

## Merge Gate

Before merging any PR, run this gate. If any check fails, stop and fix the underlying issue rather than overriding.

### Pre-Merge Checklist

- [ ] **All review threads resolved** — no unresolved conversations
- [ ] **No ongoing review, and the bot's latest review is on the head commit** (if assigned) — a `copilot_code_review` ruleset can re-block when the head changes; see "Rulesets" below
- [ ] **Rulesets checked** — `gh api repos/{owner}/{repo}/rules/branches/BASE`, not just classic branch protection
- [ ] **Branch rebased on target** — no stray merge commits in PR branch
- [ ] **All CI checks pass** — green status on every required check
- [ ] **No CI annotations** — check job annotations, not just pass/fail (see below)
- [ ] **Signed commits** — every commit in the PR is signed (see "Signing and DCO Failures" below if blocked)
- [ ] **DCO sign-off** — every commit has a `Signed-off-by:` trailer matching `git config user.{name,email}` (required when the `probot/dco` check is enabled)
- [ ] **No intermediate planning artifacts** — `bash skills/git-workflow/scripts/spec-cleanup-guard.sh` exits 0; superpowers specs/plans (`docs/superpowers/**`) and other scratch planning files must not reach the base branch (see "Spec-Cleanup Guard" below and `references/spec-cleanup.md`)

### PR-green is not main-green — jobs gated on `push`/`merge_group` don't run on the PR

A PR's checks are only the workflows that trigger on `pull_request`. A job gated on `push: [main]` (or the `merge_group` event) never runs on the PR, so a green PR does **not** clear it — the job fires *after* merge and can turn `main` red on a change the PR "passed". Before merging, diff each workflow's trigger against what actually ran on the PR; for any `push`/`merge_group`-only job (a deploy, a boot/smoke test, a container-compile), reproduce it locally on the merge result first.

This bites hardest on dependency bumps. A resolver succeeding (`composer update` / `npm install` resolves cleanly) is **necessary but not sufficient**: a loose constraint can select a *released* sibling whose code predates compatibility with the new dependency, so it installs but fails at runtime.

- Real case: a project bumped `nr-llm ^0.12 → ^0.22`. Every `pull_request` check passed. The `validate` job — gated on `push: main`, so absent from the PR — boots the app and compiles the DI container; post-merge it failed because a *released* sibling (`t3-cowriter v3.1.1`, constraint `nr-llm >=0.3 <1.0`) referenced a class the new `nr-llm` had removed. Resolution was green; the runtime compile was not. Recovery cost a sibling release plus a follow-up PR.
- Verify the runtime path, not just resolution: run the actual boot/compile (or the exact `push:main`-only job) against the resolved tree locally before merging. For the class-not-found family, a fast proxy is to confirm every referenced upstream symbol still exists at the *resolved* version.

### Auto-Merge / Merge-Queue Arming Gate

`gh pr merge --auto` is a **deferred merge with no human in the loop** — and a
merge queue only re-runs *required checks*; it does **not** wait for review
threads, bot reviews in flight, or Sonar-style informational checks. Arming at
PR creation therefore merges over unaddressed review feedback the moment CI is
green.

Arm auto-merge / enqueue **only when all three hold**:

1. **Zero unresolved review threads** (GraphQL `reviewThreads`, not the UI).
2. **All checks green** — including non-required ones you intend to honor.
3. **No pending review request** (`gh pr view --json reviewRequests` is `[]`)
   — a re-requested bot review that has not landed yet counts as pending.

Bot reviews (Copilot, Gemini) land 2–5 minutes after each push — wait that
window out before concluding "no threads".

**Review on an earlier head + `CLEAN`: decide via the timeline, not the
review list.** After a follow-up push (docs-only changes often do not
re-trigger Copilot), the only review on record may sit on a previous commit
while `mergeStateStatus` reports `CLEAN` off it. Whether that is mergeable
depends on one question: was any review (re)announced *after* the latest
push? The reviews list cannot answer it — query the timeline events:

```bash
R=<owner/repo>; PR=<number>
gh api repos/$R/issues/$PR/timeline --jq \
  '[.[] | select(.event=="review_requested" or .event=="reviewed")
        | {event, actor: (.actor.login // .user.login), at: (.created_at // .submitted_at)}]'
```

- Last `review_requested` is **before** the latest push and a matching
  `reviewed` followed it, no newer request → no review is in flight; the
  old-head review + `CLEAN` is mergeable.
- A `review_requested` **after** the latest push with no `reviewed` yet →
  a review is in flight; wait (see *Never merge over an announced review*).

**Recovery when armed too early:**

```bash
# A PR already picked up by the queue rejects --disable-auto AND branch pushes
# ("Pull request is already queued to merge"). Dequeue it via GraphQL:
PRID=$(gh api graphql -F owner=OWNER -F repo=REPO -F pr=NUMBER \
  -f query='query($owner:String!,$repo:String!,$pr:Int!){repository(owner:$owner,name:$repo){pullRequest(number:$pr){id}}}' \
  --jq .data.repository.pullRequest.id)
gh api graphql -F id="$PRID" \
  -f query='mutation($id:ID!){ dequeuePullRequest(input:{id:$id}) { mergeQueueEntry { id } } }'
# Branch is pushable again; fix threads, then re-arm through this gate.
```

**Verify a "dropped" queue entry via the issue timeline before re-arming.**
Right after a queue merge, `gh pr view --json state` can report `OPEN` and the
queue listing can show the entry gone for several minutes — the exact signature
of a silent drop, except the PR already merged. Re-arming (or re-diagnosing) on
that stale read wastes a round-trip. The issue **timeline** is authoritative:

```bash
gh api repos/{owner}/{repo}/issues/NUMBER/timeline --paginate \
  --jq '.[]? | select(.event | IN("added_to_merge_queue", "removed_from_merge_queue",
                                  "merged", "closed")) | "\(.created_at) \(.event)"'
# removed_from_merge_queue immediately followed by merged  -> it landed; do nothing.
# removed_from_merge_queue with NO merged event            -> real silent drop; re-arm.
```

Also note: queue membership is GraphQL-only — `isInMergeQueue` /
`mergeQueueEntry` are **not** `gh pr view --json` fields (the call errors);
query `pullRequest { mergeQueueEntry { state position } }` via `gh api graphql`.

**`autoMergeRequest: null` does NOT mean "not armed" on a merge-queue repo.**
When you arm a queue PR, `gh pr merge --auto` prints *"merge strategy set by the
merge queue"* and returns immediately — and `gh pr view --json autoMergeRequest`
then reports `null`, because the queue owns the merge, not GitHub's auto-merge
feature. Reading that `null` as "arming failed" and re-running `--auto` is a
wasted round-trip (and can error "already queued"). Confirm the PR is enqueued
via the GraphQL `mergeQueueEntry { state position }` or the timeline
`added_to_merge_queue` event — never via `autoMergeRequest`.

### Signing Readiness (Preflight — Before Committing)

A signing failure surfaces only at the *merge gate* (BLOCKED on DCO / "verified signatures") — i.e. **after** all the work is staged, forcing a full re-sign cycle. Catch it up front: before a commit-heavy run (e.g. `/pr-finish`), confirm a signing key is actually available and that `git commit -S` will sign, rather than assuming it.

```bash
# SSH-signing setups: is a key the agent can sign with actually loaded?
ssh-add -l        # "no identities" → signing (and any SSH git auth) will fail until re-added
# Definitive probe: a throwaway signed commit verifies, then drop it
git commit -S --allow-empty -m probe \
  && (git log --show-signature -1 | grep -q Good && echo "SIGNING READY" || echo "SIGNING NOT READY"; git reset --soft HEAD~1) \
  || echo "SIGNING NOT READY — commit failed"
```

If the probe fails (no askpass, a locked/dropped key, or a key not registered as a *signing* key), resolve it **before** doing the work — the mid-run remedy is the same `rebase --exec` re-sign as a reactive failure, but you avoid discovering it at the gate. See *Signing and DCO Failures* below for that remedy.

### Signing and DCO Failures

When `mergeStateStatus: BLOCKED` and the blocking check is `dco` or a "Commits must have verified signatures" branch-protection rule, act on these in order:

> If the unsigned commits are **someone else's** — e.g. a fork merging upstream history —
> none of the steps below apply: you cannot sign off on another author's work, and the
> rebase in Step 2 would forge it. See
> [Merging Divergent Upstream History (Forks)](#dco-and-third-party-history-are-structurally-incompatible).

**Step 1 — Verify git identity is correct (not swapped).**
A swapped name/email pair silently produces a malformed `Signed-off-by:` trailer that the DCO bot rejects:

```bash
git config user.name   # must look like "Firstname Lastname", NOT an email address
git config user.email  # must contain "@", NOT a plain name

# Fix if swapped:
git config --global user.name "Firstname Lastname"
git config --global user.email "you@example.com"
```

**Step 2 — Add missing sign-offs to all commits in the branch.**
Rebase with `--exec` to amend every commit at once. Use `--signoff` for DCO, `-S` for signature, or both:

```bash
# Both DCO sign-off and GPG/SSH signature in one pass:
git rebase origin/main --exec 'git commit --amend --no-edit --signoff -S'
git push --force-with-lease
```

**Step 3 — If signatures still show `reason: unknown_key`, the SSH key is not registered as a *Signing Key* on GitHub.**
Auth keys and signing keys are separate registrations. An authentication key cannot verify commits:

```bash
# Check commit verification after pushing:
gh api /repos/{owner}/{repo}/commits/HEAD --jq '.commit.verification | {verified, reason}'
# "reason":"valid"        → OK
# "reason":"unknown_key"  → key is not registered as a signing key
# "reason":"unsigned"     → -S flag was not used or signing config is missing
```

If `unknown_key`: go to *github.com → Settings → SSH and GPG keys*, find your key, and add it again under *New signing key* (same public key, different "Key type"). After adding, re-verify with the API call above.

### Merge-Gate Command

```bash
# The gate is TWO queries. `reviewThreads` is NOT a valid `gh pr view --json`
# field — gh errors "Unknown JSON field: reviewThreads" (its whitelist has
# reviews / reviewRequests / reviewDecision, not reviewThreads), and passing it
# fails the WHOLE call. Thread resolution is only available via GraphQL.
#
# (1) PR-level fields via gh pr view (--json takes a no-spaces comma list):
gh pr view NUMBER --json reviewDecision,mergeStateStatus,mergeable,statusCheckRollup

# (2) unresolved-thread count via GraphQL (must be 0):
gh api graphql -f query='{repository(owner:"OWNER",name:"REPO"){pullRequest(number:NUMBER){
  reviewThreads(first:100){nodes{isResolved}}}}}' \
  --jq '[.data.repository.pullRequest?.reviewThreads?.nodes[]? | select(.isResolved==false)] | length'

# Merge-ready requires ALL of:
#   reviewDecision                            == "APPROVED" OR "" (empty = no
#                                                human-approval rule; CLEAN then
#                                                already encodes the gate — do
#                                                NOT treat "" as a blocker)
#   mergeStateStatus                          == "CLEAN"
#   mergeable                                 == "MERGEABLE"
#   every statusCheckRollup[].conclusion      == "SUCCESS"
#   unresolved-thread count (query 2)         == 0
```

**The gate and the merge are two separate invocations.** Run the gate query,
read its output, and only then issue `gh pr merge` as a new command. Never
chain them (`gate-query && gh pr merge`, or query-then-merge in one
heredoc/compound command): shell chaining decides on **exit codes**, not on
the gate's content — `gh pr view` exits 0 whether it reports zero unresolved
threads or three, so the merge fires before anyone has read the gate's
output. And `mergeStateStatus: CLEAN` does **not** imply zero unresolved
threads — GitHub only couples the two when the "require conversation
resolution" branch-protection rule is enabled, which most repos don't turn on.

```bash
# ❌ Wrong — merge already executed by the time the gate output is visible
gh pr view 42 --json mergeStateStatus && gh pr merge 42 --merge

# ✅ Right — run the gate queries, READ the output, then merge as a new command
gh pr view 42 --json reviewDecision,mergeStateStatus,mergeable,statusCheckRollup
gh api graphql -f query='{repository(owner:"OWNER",name:"REPO"){pullRequest(number:42){reviewThreads(first:100){nodes{isResolved}}}}}' --jq '[.data.repository.pullRequest?.reviewThreads?.nodes[]?|select(.isResolved==false)]|length'
# READ both: all threads resolved (count 0)? all checks green? Only then:
gh pr merge 42 --merge
```

#### Diagnosing `mergeStateStatus: BLOCKED`

`BLOCKED` tells you the PR is not mergeable; it never tells you **why**. Derive the cause from the gate fields above — not from the branch-protection / ruleset inventory (`gh api repos/{repo}/rules/branches/{branch}` or `…/branches/{branch}/protection`). That inventory lists which rules *exist*, not which one is *currently failing*; reading "copilot_code_review is configured" and concluding "Copilot is blocking" is a classic false attribution. Walk the decisive evidence in this order:

| Symptom in the gate output | Actual blocker |
|---|---|
| `reviewDecision: "REVIEW_REQUIRED"` | a required approving review is missing — request/await it |
| `reviewDecision: ""` **and** still BLOCKED | **not** a review-approval block — keep looking (this is the field that disproves "a reviewer is blocking it") |
| any `statusCheckRollup[].conclusion != "SUCCESS"` (incl. pending) | a required check — name *that* check, not a rule |
| `reviewThreads[].isResolved == false` exists | unresolved conversations + the repo's `required_conversation_resolution` toggle — resolve the threads |
| all the above clean, still BLOCKED | branch behind base (needs update), or merge-queue / required-deployment gate |

When unsure which protection toggle couples to the symptom, read it directly: `gh api repos/{repo}/branches/{branch}/protection --jq '{conversation: .required_conversation_resolution, reviews: .required_pull_request_reviews, checks: .required_status_checks.contexts, strict: .required_status_checks.strict}'`. State the cause only once you can point at the field that proves it.

The PR-level gate above covers review decision, merge state, required checks, and thread resolution in one response. A second check is needed for CI annotations (warnings — reviewdog / actionlint / CodeQL deprecations — that don't fail their check but still need addressing). These are a commit-level property, not a PR-level one:

```bash
gh api "repos/{owner}/{repo}/commits/SHA/check-runs" \
  --jq '.check_runs[] | select(.output.annotations_count > 0) | {name: .name, annotations: .output.annotations_count}'
```

> **Important:** CI annotations are invisible in the PR summary view but visible in the job detail "Annotations" section on the Files Changed tab. Always check for annotations before declaring a PR clean.

For automated enforcement at tool-invocation time, see the `merge-gate.sh` hook recipe in `references/claude-code-hooks.md`. The hook enforces the **runtime-checkable subset** — `reviewDecision`, `mergeStateStatus`, and unresolved thread count — which covers the most common block reasons. Signed-commits and CI-annotations checks are not enforced by the hook (annotations in particular require the commit-level API call above); rely on the repo's branch-protection rules and local pre-commit hook for those.

> **Important:** CI checks can PASS while emitting warning annotations (e.g., actionlint/shellcheck via reviewdog, CodeQL deprecation notices). These are invisible in the PR summary view but visible in the job detail "Annotations" section. Always check for annotations before declaring a PR clean.

### Spec-Cleanup Guard

Intermediate planning artifacts (superpowers specs/plans, ad-hoc `PLAN.md`,
planning-tool output) must not ride into the base branch. The guard is
deterministic and **read-only** — it detects and reports, never deletes.

```bash
# Exit 0 = clean; exit 1 = artifacts found (resolve before merge); exit 2 = config error.
bash skills/git-workflow/scripts/spec-cleanup-guard.sh
```

If it exits 1, resolve via the `/pr-finish` spec-cleanup step (convert to an ADR /
remove / acknowledge) so the branch is clean, then re-run. Full capability —
config, three-state detection, Capture flow — is in `references/spec-cleanup.md`.

### Rulesets: the gate `gh pr view` doesn't show

`mergeStateStatus: BLOCKED` with `reviewDecision: ""`, every check green, and
every thread resolved almost always means a **repository ruleset** — rulesets
are evaluated for merge but are invisible to both the merge-gate `gh pr view`
and the classic `branches/{branch}/protection` API. Don't discover this by
trial-and-error; fetch the *effective* rules as part of the gate:

```bash
# gh resolves {owner}/{repo} from git context but NOT the branch — fill in BASE,
# the branch you merge INTO (e.g. main / develop), not the feature branch.
# The endpoint returns an array of rule objects, so group_by(.type) works:
gh api repos/{owner}/{repo}/rules/branches/BASE \
  --jq 'group_by(.type)[] | {type: .[0].type, n: length}'
```

The common culprit is a `copilot_code_review` rule: it requires a Copilot
review on the **latest commit**. A push *may* trigger a fresh review, but not
always, and Copilot is not reliably re-requested automatically — so never
assume the review state tracks your latest commit. If the gate is blocked and
the bot's latest review is on a commit that predates the head, re-request
explicitly, then re-poll the gate:

```bash
gh api repos/{owner}/{repo}/pulls/NUMBER/requested_reviewers \
  -X POST -f 'reviewers[]=copilot-pull-request-reviewer[bot]'
```

(`gh pr edit --add-reviewer` rejects the bot login with "Could not resolve
user"; the REST `requested_reviewers` endpoint is the working path.)

**Always check for an ongoing review before merging — don't merge on a
transient `CLEAN`.** A bot review can be *in progress* (after a re-request, and
sometimes after a push): `mergeStateStatus` can read `CLEAN` for a few seconds
before the bot posts its comments, and merging then strands fresh review
threads on a closed PR. A **pending review request is the in-progress signal** —
treat the PR as not ready while it persists. Poll until the request clears
*and* the bot's latest review matches the head commit `oid`:

```bash
gh api graphql -f query='{repository(owner:"OWNER",name:"REPO"){pullRequest(number:NUMBER){
  headRefOid
  reviewRequests(first:10){nodes{requestedReviewer{... on Bot{login} ... on User{login}}}}
  reviews(last:20){nodes{author{login} state commit{oid}}}}}}'  # last:N must exceed the review count
# Ready only when: no pending reviewRequests AND the bot's latest review.commit.oid == headRefOid.
```

Other ruleset rules to expect: `required_approving_review_count`, `required_review_thread_resolution`, `non_fast_forward`.

> **Front-load the whole picture.** Gather merge state, checks, rulesets,
> requested reviewers, and thread IDs in one mechanical block before reasoning
> about merge-readiness — see the Merge-Gate Command above plus this ruleset
> call. Discovering gates one round-trip at a time is the anti-pattern.

## Self-Authored PR Merge (Permission Classifier)

When you drive your own PR to merge (e.g. via `/pr-finish`), the auto-mode
permission classifier blocks self-merges and admin self-bypass — a self-authored
merge is treated as requiring a human. Do **not** attempt the merge twice and
then bounce to the human; two denials read as stalling.

- Recognize up front that finishing a self-authored PR will hit the classifier,
  and settle the merge path **before** starting.
- For archive/cleanup tasks, take the local-clone + signed-commit + PR path from
  the start — not a Contents-API commit or an admin bypass the classifier will
  reject.
- If a human merge is genuinely required, ask **one** structured question up
  front rather than discovering the block via two denials.

## Shared-Account and Parallel-Job PR Races

When several agent jobs run under the **same** git/GitHub identity (a shared
bot/CI account), a PR can be force-pushed or merged out from under your review or
take-over by a parallel job — and you cannot prove your own job didn't do it.
Defend:

1. **Snapshot head + merge state** at the start of any review/take-over, and
   re-check immediately before acting; abort or rebase if it moved:

   ```bash
   gh pr view <NUMBER> --json headRefOid,state,mergeStateStatus
   ```

2. **Never trust a pre-existing shared worktree** for review/fix — a parallel job
   may churn or delete it mid-task. Create your own isolated worktree for the PR
   branch (or off a freshly-fetched `origin/main` if starting a new branch).
3. **`gh pr diff` vs the file you `Read` disagree?** The branch was force-pushed
   between calls — re-fetch and re-derive from the committed state on origin.

## A New Gate Retroactively Raises the Bar for Sibling PRs

When one PR in a related set introduces a new check — a linter, a security scan
(zizmor/trivy), a conformance script — that check applies to the **whole repo on
every push and PR**, not just the PR that added it. Two failure modes follow, and
both surface only after a merge:

1. **Sibling PRs that predate the gate.** A second open PR adding a new file
   (e.g. a new reusable workflow) was written before the gate existed. The moment
   the gate PR merges, `main` — and that sibling PR's own CI — goes red, because
   the new file was never hardened to pass a check that didn't exist when it was
   written. Harden every sibling artifact to the new gate **before** either PR
   merges.

2. **"Validated earlier" was validated against the *old* criteria.** If you ran
   `actionlint + yamllint` on an artifact last week and then added `zizmor` to the
   gate this week, the artifact was never checked by zizmor. Passing the *previous*
   gate is not passing the *current* one — re-run the **full current** gate over
   anything you're about to merge, not the subset that existed when you first
   validated it.

**Catch it before merging, in any order.** Simulate the merged tree of the whole
PR-set and run the complete gate over it — don't reason about it:

```bash
# Three-way merge of two branches without touching either working tree.
# `--write-tree` exits non-zero on conflict; check that status with `if` rather
# than masking it through a pipe — `... | head -1` would swallow the conflict
# exit code and hand you a tree with conflict markers to lint.
git -C .bare fetch origin
if MERGE_OUT=$(git merge-tree --write-tree origin/pr-a-branch origin/pr-b-branch); then
    TREE=$(printf '%s' "$MERGE_OUT" | head -1)   # first line is the merged tree OID
    # Materialize $TREE and run every gate check (lint, security, conformance),
    # or just run the checks in each PR's branch after rebasing it on the other.
else
    echo "PRs conflict on merge — resolve the conflict before checking the gate"
fi
```

If the gate is green on both PRs individually **and** on their merged tree, they
are safe to merge in any order. If only the individuals are green, the first
merge will break the second.

## Signed Commits with Rebase Merge

### The Problem

When a repository requires:
1. Signed commits AND
2. Only rebase merge (no merge commits, no squash)

GitHub **cannot** sign rebased commits automatically:

```bash
gh pr merge 123 --rebase
# Error: Base branch requires signed commits.
# Rebase merges cannot be automatically signed by GitHub.
```

### The Solution: Local Fast-Forward Merge

Since commits are already signed locally, merge locally and push:

```bash
# 1. Ensure local main is up to date
git checkout main
git pull origin main

# 2. Verify feature branch is rebased (should be fast-forward)
git log --oneline main..feature-branch

# 3. Fast-forward merge (preserves original signatures)
git merge feature-branch --ff-only

# 4. Push to main
git push origin main

# 5. Close the PR (it will auto-close if commits match)
# Or manually: gh pr close NUMBER
```

### Why This Works

- Original commits retain their GPG/SSH signatures
- Fast-forward merge doesn't create new commits
- GitHub recognizes the commits and auto-closes the PR

### When to Use

| Scenario | Solution |
|----------|----------|
| Signed commits required + squash allowed | `gh pr merge --squash` (GitHub signs) |
| Signed commits required + merge commit allowed | `gh pr merge --merge` (GitHub signs merge commit) |
| Signed commits required + rebase only | Local fast-forward merge (this solution) |

### Automation Option

```bash
#!/bin/bash
# merge-signed-pr.sh - Merge PR with signed commits via fast-forward

PR_NUMBER=$1
BRANCH=$(gh pr view $PR_NUMBER --json headRefName -q '.headRefName')

git fetch origin
git checkout main
git pull origin main

# Verify it's a fast-forward
if ! git merge-base --is-ancestor main origin/$BRANCH; then
    echo "Error: Branch needs rebase first"
    exit 1
fi

git merge origin/$BRANCH --ff-only
git push origin main

echo "PR #$PR_NUMBER merged via fast-forward"
```

## GitLab: the same gate with `glab` (merge requests)

Everything above assumes GitHub. GitLab has the same concepts under different
field names, a different CLI and a different thread model — translate it, don't
improvise mid-run. Export `GITLAB_HOST` (or pass `--hostname`) for self-managed
instances.

### One-block preflight

The GitLab analogue of the `gh pr view` + rulesets + `reviewThreads` block.
Run it once, up front, and re-run only after a state-changing push. Note that
`glab api` has no `--jq` flag (verified on glab 1.95.0) — unlike `gh api`, pipe
its output to `jq`:

```bash
export GITLAB_HOST=git.example.com
P=<group>%2F<project>          # URL-encoded path, or the numeric project id
M=<mr_iid>

# (1) MR state and WHY it is blocked. detailed_merge_status names the blocker;
#     merge_status alone does not.
glab api "projects/$P/merge_requests/$M" \
  | jq '{state,draft,merge_status,detailed_merge_status,has_conflicts,
         blocking_discussions_resolved,user_notes_count,sha,target_branch,title}'

# (2) approval rule and who approved (approvals_required null = no rule)
glab api "projects/$P/merge_requests/$M/approvals" \
  | jq '{approvals_required,approved_by:[.approved_by[].user.username]}'

# (3) threads. individual_note==true is a plain comment, not a thread.
glab api "projects/$P/merge_requests/$M/discussions" \
  | jq '[.[] | select(.individual_note|not)
         | {id, resolved: .notes[0].resolved, author: .notes[0].author.username}]'

# (4) what protects the target branch (GitLab's answer to rulesets).
#     Use the target_branch from (1) — it is not always the default branch.
glab api "projects/$P/protected_branches/<target-branch>"

# (5) pipeline on the MR head SHA
glab ci status --branch <source-branch>

# (6) how this project merges — so you do not squash by accident
glab api "projects/$P" | jq '{merge_method,squash_option,
  only_allow_merge_if_pipeline_succeeds,remove_source_branch_after_merge}'
```

### Field mapping

| GitHub | GitLab |
|---|---|
| `mergeStateStatus` (`BLOCKED` / `CLEAN`) | `detailed_merge_status` (`draft_status`, `not_approved`, `discussions_not_resolved`, `ci_must_pass`, `mergeable`, …) |
| `mergeable` | `merge_status` + `has_conflicts` |
| `reviewDecision` | `approvals_required` + `approved_by` (`/approvals`) |
| GraphQL `reviewThreads[].isResolved` | `/discussions` → `notes[0].resolved`; aggregate flag `blocking_discussions_resolved` |
| `resolveReviewThread` mutation | `PUT /merge_requests/:iid/discussions/:id?resolved=true` |
| Rulesets (`/rules/branches/main`) | `/protected_branches/:name` + approval rules |
| `statusCheckRollup` | `glab ci status` / `/pipelines` |
| Draft PR | `draft: true` → `glab mr update <iid> --ready` |

`detailed_merge_status: draft_status` means the **only** blocker is the draft
flag. That is the most common "the MR refuses to merge and nothing looks wrong"
case — check it before hunting for approvals or failing jobs.

### Replying to and resolving a thread

Reply *into* the thread, never as a new top-level comment, then resolve and
verify — the same discipline as the GitHub GraphQL flow:

```bash
glab api -X POST "projects/$P/merge_requests/$M/discussions/<discussion_id>/notes" \
  -f body="Fixed in <sha>. <what changed and why>"

glab api -X PUT "projects/$P/merge_requests/$M/discussions/<discussion_id>?resolved=true"

# verify — the aggregate flag must be true before merging
glab api "projects/$P/merge_requests/$M" | jq .blocking_discussions_resolved
```

### Merge

```bash
# Check merge_method FIRST (preflight 6): "merge" -> merge commit,
# "ff" -> fast-forward only, "rebase_merge" -> semi-linear.
# Never pass --squash unless the user asked for it.
glab mr merge "$M" --remove-source-branch --yes
```

`glab mr merge` waits for the pipeline and refuses while it is still running, so
a green pipeline is a precondition of the command rather than something to
re-check afterwards.

### Rebase when the MR is behind

GitLab will happily report `mergeable` while the branch is behind the target —
being behind is not a blocker there, unlike a GitHub merge queue. If the
procedure calls for a rebase, drive it locally and fetch the base explicitly
(bare-repo worktrees often lack `remote.origin.fetch`, and `--force-with-lease`
then fails with "stale info"):

```bash
git fetch origin <target-branch>:refs/remotes/origin/<target-branch>
git rebase origin/<target-branch>
git push --force-with-lease origin <source-branch>
```

Re-run the preflight afterwards: the rebase produces a new head SHA, so the
pipeline result you looked at no longer applies.

## Full PR Lifecycle Checklist

Complete end-to-end workflow for merging a PR, from CI verification through post-merge cleanup.

### 1. Verify CI Status

```bash
# Check all checks
gh pr checks <NUMBER>

# If failing, get detailed error logs
gh run view <RUN_ID> --log-failed 2>&1 | grep "There were"

# Check annotations (warnings that don't block but should be fixed)
gh api "repos/OWNER/REPO/commits/SHA/check-runs" \
  --jq '.check_runs[] | select(.output.annotations_count > 0) | {name, annotations: .output.annotations_count}'
```

### 2. Resolve Review Comments

**Work threads the moment they land — decoupled from CI.** Review comments
are workable input 2–5 minutes after a push; there is no reason to wait for
the full check matrix before starting on them. Poll `reviewThreads`
independently of `gh pr checks` (a watcher that gates thread reporting on
"all checks settled" hides actionable feedback for the length of the longest
job). Bot reviews also race your pushes: a thread may flag code a commit you
just pushed already fixed — answer it with the fixing SHA and resolve; no
churn needed.

```bash
# List unresolved threads
gh api graphql -f query='query {
  repository(owner: "OWNER", name: "REPO") {
    pullRequest(number: NUMBER) {
      reviewThreads(first: 30) {
        nodes {
          id
          isResolved
          comments(first: 1) {
            nodes { body author { login } }
          }
        }
      }
    }
  }
}' --jq '.data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved == false) | {id, author: .comments.nodes[0].author.login, comment: .comments.nodes[0].body[:100]}'

# Reply to a thread
gh api graphql -f query='mutation($body: String!, $id: ID!) {
  addPullRequestReviewThreadReply(input: {body: $body, pullRequestReviewThreadId: $id}) {
    comment { id }
  }
}' -f body="Fixed in latest commit." -f id="PRRT_xxx"

# Resolve a thread
gh api graphql -f query='mutation { resolveReviewThread(input: {threadId: "PRRT_xxx"}) { thread { isResolved } } }'
```

### 3. Merge

```bash
# Auto-detect merge strategy and queue.
# Prefer atomic-history methods; NEVER auto-pick squash (see "Never squash
# unless the user asks" above). Squash is selected only if it is the sole
# method the repo allows — and then warn, because it rewrites history.
STRATEGY=$(gh api "repos/OWNER/REPO" --jq '
  if .allow_merge_commit then "--merge"
  elif .allow_rebase_merge then "--rebase"
  elif .allow_squash_merge then "--squash"
  else "" end') || { echo "ERROR: could not query repo merge methods" >&2; exit 1; }
# Fail fast rather than fall through to gh's default method (which may be squash).
[ -z "$STRATEGY" ] && { echo "ERROR: no merge method enabled on this repo" >&2; exit 1; }
[ "$STRATEGY" = "--squash" ] && echo "WARNING: only squash is enabled — this rewrites history and drops signatures" >&2
gh pr merge <NUMBER> --auto "$STRATEGY"

# For repos with merge queue, queue it — but ONLY after passing the
# "Auto-Merge / Merge-Queue Arming Gate" above (the queue ignores
# unresolved review threads and in-flight bot reviews).
gh pr merge <NUMBER> --auto
```

### 4. Post-Merge Cleanup

```bash
# Switch to main and pull
git checkout main && git pull

# Delete local feature branch
git branch -d <branch-name>

# Remote branch is auto-deleted if repo setting enabled, otherwise:
git push origin --delete <branch-name>
```

### Common Blockers

| Blocker | Diagnosis | Fix |
|---------|-----------|-----|
| `REVIEW_REQUIRED` but no pending reviewers | Auto-approve raced with Copilot review | Re-run PR Quality Gates workflow |
| `BLOCKED` with all checks green | Unresolved review threads (even from old commits) | Resolve all threads via GraphQL |
| Auto-merge dropped after push | New commits nullify `autoMergeRequest` | Re-queue with `gh pr merge --auto` |
| CI annotations but status green | Reviewdog warnings don't block by default | Fix annotations or set `fail_level: error` |
| `startup_failure` / "no jobs ran" / config invalid | Workflow validator rejected the run before any job started | Read annotations first (see [Diagnosing CI Failures (Annotations First)](#diagnosing-ci-failures-annotations-first) above) — the literal validator error is in one line |
