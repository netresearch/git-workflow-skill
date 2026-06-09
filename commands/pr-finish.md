---
name: pr-finish
description: "Drive a PR to merge — rebase, fix CI, resolve review comments, update title/description, merge when green"
---

# /pr-finish

Bring the pull request to a fully-green, merged state. This is the canonical
PR-completion request, so it runs through the **git-workflow** skill every time.

**First, invoke the `git-workflow` skill** — its `references/pull-request-workflow.md`
is authoritative for the merge gate, GraphQL thread resolution, and merge-queue
handling. Then execute, in order:

0. **Preflight — fetch the whole merge-gate picture in ONE mechanical block,
   before reasoning about merge-readiness.** Never discover a gate (BLOCKED,
   required reviews, rulesets, unresolved threads, failing checks) one
   round-trip at a time — `mergeStateStatus: BLOCKED` alone never tells you
   *why*. Run this up front and re-run only after a state-changing push:

   ```bash
   R=<owner/repo>; PR=<number>; BASE=<base-branch>
   gh pr view   $PR --repo $R --json state,mergeable,mergeStateStatus,reviewDecision,headRefOid,baseRefName,title
   gh pr checks $PR --repo $R
   gh api repos/$R/rules/branches/$BASE   # effective rules INCL. rulesets (e.g. copilot_code_review) — evaluated against the BASE branch; classic branch-protection API misses these
   gh pr view   $PR --repo $R --json reviewRequests --jq '.reviewRequests'
   gh api graphql -F owner="${R%/*}" -F repo="${R#*/}" -F pr="$PR" -f query='query($owner:String!,$repo:String!,$pr:Int!){repository(owner:$owner,name:$repo){pullRequest(number:$pr){reviewThreads(first:50){nodes{id isResolved comments(first:1){nodes{databaseId author{login} path body}}}}}}}'
   ```

   This yields, in one shot: merge state + why, every required check, **rulesets**
   (a CLEAN-blocking `copilot_code_review` rule needs a fresh Copilot review on
   the *latest* commit — re-request via `gh api repos/$R/pulls/$PR/requested_reviewers -X POST -f 'reviewers[]=copilot-pull-request-reviewer[bot]'`), pending review requests, and the thread IDs needed to reply to and resolve each thread. Reason once from this, not serially.

1. **Rebase** onto the base branch if the branch is behind. In bare-repo worktree
   setups, fetch explicitly (`git fetch origin <branch>:refs/remotes/origin/<branch>`)
   — `origin/*` may not auto-update and `--force-with-lease` then fails "stale info".
   Force-push only with `--force-with-lease`, never plain `--force`.
2. **Fix CI** — run the full local suite first (tests, type-check, linters/formatters
   as applicable) and fix everything locally; don't push half-fixes that re-trigger
   CI. For Python projects with ruff, run both `ruff format` and `ruff check` before
   committing.
3. **Resolve every review thread** — reply directly to each thread via the GraphQL
   `addPullRequestReviewThreadReply` mutation (using the thread ID from preflight, never
   a general PR comment), reference the fixing commit, then resolve the thread via the
   GraphQL `resolveReviewThread` mutation. Verify `isResolved` — green CI alone is not
   sufficient.
4. **Update the PR title and description** to match the final state.
5. **Merge only when fully green AND all threads resolved.** Use `--merge` or
   `--rebase`, never `--squash` (preserve atomic history). **`mergeStateStatus: CLEAN`
   is not sufficient** — a `copilot_code_review` ruleset with `review_on_push:false`
   stays satisfied by an *earlier* commit's review, so CLEAN can report green while the
   head commit is unreviewed. Before merging, confirm the latest review from each required
   reviewer is on the current `headRefOid` (not a prior commit) **and** `reviewRequests`
   is empty — an empty list means the reviewer *finished*, not that a freshly-requested
   review can be skipped. Never merge with a review in flight; if you re-request a reviewer,
   wait for its review on the head commit to land first. Dependabot/Renovate PRs auto-merge
   via the repo's deps workflow — never merge those by hand.
6. **Post-merge:** confirm any merge-triggered async jobs, and clean up the branch.

No version bumps or CHANGELOG entries in feature PRs. No bot attribution in
commits or PR bodies. Preserve commit signing.

If the user named a PR (`$ARGUMENTS`), operate on that one; otherwise resolve the
PR for the current branch. Also check already-closed PRs for unresolved threads
when the user asks for a sweep. Confirm before any push to a private repo.
