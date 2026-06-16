---
name: pr-finish
description: "Drive a PR to merge — rebase, fix CI, resolve review comments, update title/description, merge when green"
---

# /pr-finish

Bring the pull request to a fully-green, merged state. This is the canonical
PR-completion request, so it runs through the **git-workflow** skill every time.

**First, invoke the `git-workflow` skill** — its `references/pull-request-workflow.md`
(under `skills/git-workflow/`) is authoritative for the merge gate, GraphQL thread
resolution, and merge-queue handling. Then execute, in order:

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
   (if a `copilot_code_review` rule is blocking because no review has been triggered yet,
   you can request one via `gh api repos/$R/pulls/$PR/requested_reviewers -X POST -f 'reviewers[]=copilot-pull-request-reviewer[bot]'` — but once requested you must wait for it to land before merging; see step 5, never merge over an in-flight review), pending review requests, and the thread IDs needed to reply to and resolve each thread. Reason once from this, not serially.

   **Spec-cleanup gate (run before step 1, while the branch is yours to clean).**
   Run `bash skills/git-workflow/scripts/spec-cleanup-guard.sh` (or the repo's
   installed path). If it reports intermediate planning artifacts — superpowers
   specs/plans (`docs/superpowers/**`), ad-hoc `PLAN.md`, planning-tool output —
   that would reach the base branch, resolve them first: **convert** the durable
   decisions into an ADR (propose the diff, get review, commit), then **remove**
   the raw files recoverably (never bare-`rm` an untracked file; `git add -- <that
   path>` only — never `-A/-u` — so it enters history, then `git rm` in a
   `chore: remove working specs/plans` commit),
   or **acknowledge** "nothing durable" with a `Spec-Cleanup: acknowledged`
   trailer. Verify the capture commit landed before removing. Do this before the
   rebase so the branch is clean when the gate runs. See
   `skills/git-workflow/references/spec-cleanup.md`.

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
   sufficient. **Work threads the moment they land — never gate thread work on the CI
   matrix settling** (bot reviews are actionable 2–5 min after a push; a thread may
   target a pre-push range a later commit already fixed — answer with the fixing SHA
   and resolve).
4. **Update the PR title and description** to match the final state.
5. **Merge only when fully green AND all threads resolved** — `--merge` or `--rebase`,
   never `--squash` (preserve atomic history). **Never merge while a review is announced
   or in flight.** Once a reviewer is requested or has *started* — by you, a ruleset, or
   automation — its pendency blocks the merge until it resolves, regardless of what
   `mergeStateStatus` says (a `review_on_push:false` ruleset can report `CLEAN` off an
   *earlier* commit's review while a new one runs). `reviewRequests: []` is **not** "all
   clear": a reviewer that has *started* drops off the request list without having
   submitted — check the PR timeline or reviews list, not just that list. Requesting a
   reviewer commits you to waiting for it — never request one and then merge before it
   responds. You don't force a review to materialize where none is required (reviews may
   legitimately never run), but any review that *is* announced must finish.
   Dependabot/Renovate PRs auto-merge via the deps workflow — never merge those by hand.
   **Merge-queue repos: arm `gh pr merge --auto` only after this gate passes** (threads
   resolved + checks green + no pending review request) — the queue ignores review
   threads, so arming at PR creation merges over unaddressed feedback; a queued PR
   rejects branch pushes and needs the GraphQL `dequeuePullRequest` mutation to recover
   (see the skill's pull-request-workflow reference, "Arming Gate").
6. **Post-merge:** confirm any merge-triggered async jobs, and clean up the branch.

No version bumps or CHANGELOG entries in feature PRs. No bot attribution in
commits or PR bodies. Preserve commit signing.

If the user named a PR (`$ARGUMENTS`), operate on that one; otherwise resolve the
PR for the current branch. Also check already-closed PRs for unresolved threads
when the user asks for a sweep. Confirm before any push to a private repo.
