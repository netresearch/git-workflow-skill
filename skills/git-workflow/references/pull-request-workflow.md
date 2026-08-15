# Pull Request Workflow

Covers the PR lifecycle for Netresearch repos: branch and tooling checks
before opening a PR, commit discipline, merge strategies, review-thread
resolution, and the merge gate. See `references/commit-conventions.md` for
commit message formatting.

## Start Here: `scripts/pr-status.sh`

**Do not probe the merge gate one endpoint at a time.** `mergeStateStatus:
BLOCKED` never says *why*, and the reason lives in five different places:
checks, rulesets, review threads, whether a review exists on the *current*
head, and the repository's allowed merge methods.

The script is not on `PATH`, and you run it from the repository under
inspection, so a relative `./scripts/…` misses. Bind the skill directory once,
then call it by that path:

```bash
# sort -V, not plain sort: 1.10.0 must beat 1.9.0. A directly installed
# skill sorts after the cache paths and so wins when both exist.
GW=$(ls -d ~/.claude/skills/git-workflow \
        ~/.claude/plugins/cache/*/git-workflow/*/skills/git-workflow \
        2>/dev/null | sort -V | tail -1)

bash "$GW/scripts/pr-status.sh" -R owner/repo 123        # human summary + NEXT action
bash "$GW/scripts/pr-status.sh" -R owner/repo 123 --json # for scripts and merge drivers
bash "$GW/scripts/pr-status.sh" -R owner/repo 123 --watch
```

Two API calls, and the output ends in a computed `NEXT:` — rebase, fix-ci,
triage-ci, resolve-threads, request-review, wait, or merge (with the method
this repo actually allows and a warning when a merge queue is active). The
JSON form carries each unresolved thread's `threadId` *and* `commentId`, which
is everything needed to reply and resolve without another query.

Measured on a 40-PR rollout that did not have it: **183 of 370 shell calls
were PR-status probing**, the rulesets endpoint was queried exactly once, and
`copilot_code_review` blocked four merges by surprise.

**GitHub only.** The script speaks GitHub GraphQL, so it cannot answer for a
GitLab merge request — `-R git.netresearch.de/group/project` is accepted at the
command line and then fails with a bare `pr-status: GraphQL query failed`, and
`--watch` produces nothing at all until it is killed. Nothing in the name says
so, which is how a GitLab MR ended up behind a watcher that could never fire.
For GitLab the equivalent is one `glab api` call:

```bash
P=$(printf %s 'group/project' | jq -sRr @uri)   # the path must be URI-encoded
glab api "projects/$P/merge_requests/123" \
  | jq '{state, detailed_merge_status, pipeline: .head_pipeline.status}'
glab api "projects/$P/merge_requests/123/discussions" \
  | jq '[.[] | select(.notes[0].resolvable==true and .notes[0].resolved==false)] | length'
```

`detailed_merge_status` is GitLab's counterpart to `mergeStateStatus` and,
unlike it, does name the reason.

## Then Merge: `scripts/pr-merge.sh`

```bash
./scripts/pr-merge.sh -R owner/repo 123
./scripts/pr-merge.sh -R owner/repo 123 --dry-run   # print the command only
```

It reads `pr-status.sh --json` and refuses unless `NEXT` is `merge`, printing
the gate that is shut instead. When it does merge it uses the method the
repository allows and drops `--delete-branch` where a merge queue is active.
Afterwards it reads the PR back and reports only what it observed — `merged`
when the state says so, `queued` when the PR really holds a queue entry, and a
failure with exit 2 otherwise. `gh pr merge` exiting 0 proves nothing on a
merge-queue repo; see *A pending auto-merge request silently swallows the
enqueue* below.

Both of those are silent traps for a hand-written `gh pr merge --merge
--delete-branch`. A repository with `allow_merge_commit: false` answers
"Merge commits are not allowed on this repository"; one with a merge queue
answers "Cannot use `--delete-branch` when merge queue enabled". A 54-repository
rollout hit each of them three times before the detection was written down
once. Squash is never used — it discards the atomic commits and their
signatures.

### `--watch` returns on the first actionable event, not at full settle

An `until [ pending == 0 ]` loop learns nothing until the slowest matrix job
ends — long after the first failure was visible and workable. Across sessions,
45 such loops were written against 2 of any other shape. `--watch` returns as
soon as a check fails, a thread needs an answer, a review is missing, or the
required checks conclude. **Start fixing what is already red instead of
waiting for green checks you do not need.**

### Never merge an unreviewed PR

If `pr-status.sh` reports `reviews: NONE on current head`, do not merge.
Request one and say so:

```bash
gh api repos/OWNER/REPO/pulls/N/requested_reviewers -X POST \
  -f "reviewers[]=copilot-pull-request-reviewer[bot]"
```

A force-push invalidates a prior review: the old review stays attached to the
old commit, so a repo with a `copilot_code_review` rule goes back to BLOCKED
and needs a fresh request against the new head.

#### A failed Copilot review looks exactly like a delivered one

Copilot reports its own failures *as a review* — a normal `COMMENTED` row whose
body is the error:

```text
Copilot encountered an error and was unable to review this pull request.
Copilot was unable to review this pull request because the user who requested
the review has reached their quota limit.
```

Nothing in the review's `state` distinguishes that from a real review, so
"a review exists on the head" is not the same as "this PR was reviewed".
`pr-status.sh` detects it and reports `copilot_review_errored: true` with
`NEXT: request-review` and a `copilot_error_count`. From the second failure on a
head it drops the retry command and tells you to review it yourself — in every
repo, with or without the `copilot_code_review` ruleset, since the generic
review gate re-requests the same bot. By hand, read the review **body**, not
just its state.

The action stays `request-review` even then, deliberately. The tool cannot
observe that a human read the diff — a review by the PR author is excluded from
the review gate by design — so a distinct "you are done now" action would be one
nothing could ever satisfy, and it would re-fire forever on the operator it was
written for.

The failure is also a failing `copilot-pull-request-reviewer` check-run — but
only in the REST `check-runs` API. It is **absent from GraphQL
`statusCheckRollup`**, so a rollup-based check cannot see it.

Re-request once. If it fails a second time, stop retrying and **review it
yourself**: an outage may clear, but a quota ceiling does not clear by asking
again, and the alternatives — merging unreviewed or waiting indefinitely on
third-party infrastructure — are both worse than a self-review that says so.

A body naming the **quota** is not an outage, so it costs no second strike:
`pr-status.sh` withholds the retry command on the first failure and remembers
the wall in
`${XDG_CACHE_HOME:-~/.cache}/pr-status/copilot-quota-exhausted-YYYY-MM`. The
quota is account-wide and monthly while the evidence is per PR — a pull request
nobody ever requested a review on carries none at all — so without that file
the next PR in the next repo is handed a `requested_reviewers` POST the same
exhausted quota rejects (`netresearch/maint` #52 and #53, hours after the wall
was proven elsewhere). Later runs read the marker, report
`copilot_quota_exhausted: true` and answer with the self-review guidance and no
command. The month is in the **filename**, so the marker stops applying at the
reset rather than being aged out; delete the file to undo a verdict recorded in
error.

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

### The quotas are session-shared pools — act, don't re-preflight

Every `gh` call in a session draws from a shared pool — REST 5,000/h and
GraphQL 5,000 points/h are SEPARATE pools, each shared across watchers,
agents and scripts, plus short burst limits on top. A heavy session (fleet
survey, repeated preflight batteries, parallel reviewers) usually kills the
**GraphQL pool first** — and `gh pr merge`, `gh pr view --json`, and
`pr-status.sh` are GraphQL-backed, so exactly the merge you verified
everything for stops working (observed 2026-08-13, between "all gates green"
and the merge).

Two practices keep this from biting:

- **When the full gate was verified on head X and nothing was pushed since,
  the action is ONE call — not another preflight battery.** The REST merge
  endpoint takes a `sha` pin whose 409 on mismatch IS the freshness check:

  ```bash
  gh api -X PUT "repos/$R/pulls/$PR/merge" \
    -f merge_method=merge -f "sha=$(git rev-parse HEAD)"
  ```

  Take the SHA from local git, never by retyping a short SHA into a long one
  — the pin rejects a fabricated tail exactly as it rejects a moved head.
- **GraphQL dead ≠ blocked.** The REST twins keep answering: merge (above),
  branch delete (`gh api -X DELETE repos/$R/git/refs/heads/<branch>`; a 422
  means auto-delete beat you to it), reviews and comments lists. `gh api
  rate_limit` is exempt and tells you both pools' reset times. Prefer one
  `--watch` over repeated status reads, and stop any watcher whose answer
  you already have.

## Describing the Change (PR Body, Commit Message, Issue)

The rest of this file is about getting a change *merged*. This section is about
making it *reviewable*. A reviewer who cannot see what changed has to reproduce
your work before they can judge it.

### Show before/after for anything observable

If the change alters output, an error message, a rendered page, a CLI line or an
API response, the PR body carries **both states**. Not a description of them —
the captured text:

```markdown
**Before**

    Reason: An error occured on handling the request.

**After**

    Reason: An error occured on handling the request. (HTTP 500, code 1603956982)
```

Produce them the same way: run the old and the new code against the *same*
input. A stub server, a fixture, or `git checkout <base> -- <file>` for one run
and back again all work, and take a couple of minutes:

```bash
run_it > after.txt
git checkout <base> -- src/Thing.php   # old behaviour; <base> is the PR's target, not always main
run_it > before.txt
git checkout HEAD -- src/Thing.php     # restore; verify with git status
```

Say in the body that the transcripts are captured output rather than
illustrations — the difference matters to a reviewer deciding how much to trust
them.

Cover the shapes the change can meet, not only the motivating one. A table of
input → before → after exposes the cases you would otherwise never run.

### "Unchanged" is a claim, and needs the same proof

Negative claims escape verification because nothing looks wrong when you skip
them. "The fallback keeps its wording", "existing callers are unaffected",
"no behaviour change for empty input" — each asserts the result of a run you
have to actually perform.

Build the before/after table *before* writing the summary sentence. Filling in
the rows is what catches the case you assumed was untouched; writing the
sentence first only records the assumption.

### A PR body describes the branch it had, not the branch it has

A body written months ago documents a state the branch has since left. Every
rebase, revert and upstream merge invalidates part of it, and nothing in the
tooling notices. Before publishing an update, re-derive each factual claim from
`git diff <target>...HEAD` — image tags, memory limits, thresholds, and above
all the New/Changed column: a job listed as **New** that the target already has
hides whatever your version alters about it.

Observed in one MR: a "switched coverage to PCOV" section after PCOV had been
reverted, `php:8.3` images that were `8.4`, `MSI 70/80` against an actual
`19/77`, and a job marked **New** that existed upstream — which concealed that
the change also dropped its memory limit from 2G to 512M.

When a change is gone, **delete its section**. Rewording it to "X stays the
coverage driver" replaces a false statement with a true but empty one: the body
is the delta against the target, and something that does not change has no row
in it.

**Elapsed time is the obvious cause; a review is the frequent one, and it fires
within the hour.** The body was written to describe the first version of the
change, the review found that version wrong, and the fix replaced the approach
the body still explains. Seen on one PR the same day it opened: the body
documented an escape hatch read from the environment that the head commit had
already replaced with one read off the command line — the mechanism was gone,
the explanation was not.

Re-derive the body after every push that answers a review, not only after a
rebase, and **re-measure every number it states rather than copying it
forward**. Figures survive edits that invalidate them: the same PR claimed a
"63k-word corpus" while the code comment beside the measurement said 60k. Both
had been measured — of different corpora, weeks apart in reading order and
minutes apart in writing — which is exactly why the disagreement is worth
catching. Two figures for one quantity means at least one is answering a
question you are no longer asking.

### When you already have the fix, lead with it

Issue templates order evidence before solution — they are written for reports
where the cause is still unknown. When you arrive with a diagnosis *and* a
patch, that ordering buries the actionable part under everything that proves it,
and a maintainer reading top-down never reaches it.

State the fix in the summary, then keep the evidence below it:

```markdown
### Summary

<symptom, one paragraph>

**The fix is to <X>** — <why it is safe>. Diff under [Possible fixes](#possible-fixes)
below; everything in between is the evidence for the diagnosis.
```

Keep the template's sections — reviewers navigate by them — and add the pointer
rather than reordering them.

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

**A SAST finding you actually fixed leaves its thread open too — and that thread still blocks the merge.** The case above is the *false positive*. The opposite case looks identical from `mergeStateStatus` and must not be handled the same way: you push a real fix, the analyzer re-scans and closes the issue, the quality gate flips to green — and the `github-advanced-security` review thread stays open, holding the PR at `BLOCKED` with zero failing checks and nothing obvious to fix. The thread is a snapshot of the commit it was posted against; a re-scan does not retract it.

Before assuming either case, ask the analyzer which one you are in:

```bash
# SonarCloud: is this issue actually resolved on the PR?
# Header auth, not `curl -u` — keeps the token out of the process list, and
# secret scanners flag the `-u` form on sight.
curl -s -H "Authorization: Bearer $SONAR_TOKEN" \
  "https://sonarcloud.io/api/issues/search?issues=$KEY&pullRequest=$PR&componentKeys=$PROJECT" \
  | jq '.issues[] | {rule, status, resolution}'
# -> {"status":"CLOSED","resolution":"FIXED"}  = you fixed it
# -> {"status":"OPEN"}                          = not fixed; fix or dismiss
```

The issue key is embedded in the thread body as `<!--SONAR_ISSUE_KEY:...-->`. For CodeQL, `gh api repos/$R/code-scanning/alerts/$N --jq '{state, fixed_at, dismissed_reason}'` answers the same question.

On `CLOSED / FIXED`, treat it as an ordinary already-fixed bot thread: reply with the fixing SHA and resolve. **Do not dismiss the alert** — dismissal records "we decided not to act" on a finding you did act on, which is a false audit trail and hides the rule from firing again. Dismissal is only for the intentional-finding case above.

Observed 2026-07-30 on a `docker:S8544` finding: gate `OK`, 0 open issues, 0 failing checks, `mergeStateStatus: BLOCKED` on one stale thread — a merge that looked inexplicably stuck until the thread was read.

### `gh pr update-branch` re-writes the head UNSIGNED

Both forms (merge and `--rebase`) create the new commit server-side, signed by
nobody. In a repo that requires signed commits — including a requirement
living in **classic branch protection**, which neither the rulesets endpoint
nor a non-admin protection query can see — the PR then sits at
`mergeStateStatus: BLOCKED` with every visible gate green (observed on a PR
that reported request-review for an hour while the real blocker was the
signature). Rebase locally instead: signing is wired into git, so a plain
`git rebase origin/main` (or `git commit --amend --no-edit` when only the
signature is missing) re-signs, then push with `--force-with-lease`. Two
traps in that push: a checkout created from `FETCH_HEAD` has no lease
baseline and fails with `stale info` — pass the lease explicitly as
`--force-with-lease=<branch>:<remote-sha>`; and that remote SHA must be
**measured** (`git ls-remote origin <branch>`), never retyped from memory.

### Signature verification: the GitHub API is the source of truth, not your keyring

For "is this commit signed?" in a review, ask the API:

```bash
gh api repos/OWNER/REPO/commits/SHA --jq '.commit.verification'   # verified: true|false, reason
```

Local `git log --show-signature` / `--format='%G?'` only consults the reviewer's local keyring — a status of `E` means "key not imported here", NOT "unsigned". Flagging `%G? = E` as a missing signature produces a false finding the contributor cannot fix (one such finding had to be publicly retracted; GitHub showed "verified" all along).

### A systemic failure mode gets fixed centrally — not per-symptom plus a follow-up issue

When a PR fixes one code path of a failure that can occur on every path (one endpoint catching a session-expiry redirect while all endpoints share the failure mode), the review recommendation is NOT "keep it narrowly scoped + open a follow-up for centralization". Rework the fix at the central layer (session hook, base class, middleware) — the symptom-fix then becomes unnecessary or trivial. Opening a follow-up issue "for the real fix later" is the smell that the current PR sits in the wrong place: it cements the wrong location, ships a known-imperfect fix, and adds tracking overhead to undo. The only accepted split: the central fix has a hard external dependency that genuinely cannot land in the same PR.

### Triage findings one by one — batched "out of scope" hides cheap fits

When several reviewers (or parallel review agents) return a list of findings, do not sort them into "applied" vs "out of scope" as a batch. Fit-check each finding individually first:

1. **Does it require a code change at all?** "Document the invariant" / "explain the discarded return" is a comment-only addition — it fits in any PR that touches the code it explains.
2. **If it needs code: is it under ~10 lines and inside already-touched files?** Then it fits.
3. **Is there a doc-only alternative?** A comment documenting the trade-off often satisfies the concern at near-zero cost.

Default to "fits" for comment- or docstring-only suggestions; reserve "out of scope" for real surgery (interface changes, cross-file refactors, unrelated pre-existing bugs). In one 12-finding round, batching hid two one-line doc-comment additions among genuinely out-of-scope refactors — the reviewer asked "none of them fit?" and the re-examination cost an extra round-trip.

When you do defer a finding, "filed as follow-up" is a claim of action: file the issue in the same turn and quote its URL in the summary, or ask explicitly whether to file — never write "will file" / "tracked separately" without the link in the same paragraph.

### A suggestion against verbatim material is a suggestion to falsify it

Reviewers read a diff, not its provenance. When a comment proposes tidying something
that was **copied verbatim** — a captured transcript, a quoted log line, an error
string, a fixture recorded from a real system — check the source of truth before
touching it. Improving such a line does not improve the artifact; it turns evidence
into an approximation, and quietly breaks anyone who greps their own logs for the
string as it is actually emitted.

**Real case:** a review asked to correct "occured" to "occurred" in a before/after
transcript. The misspelling belonged to the server under discussion:

```php
// ter_rest/Classes/Http/RouteHandler.php:125, quoted as it stands
: $this->responseFactory->createErrorResponse($request, 1603956982, 'An error occured on handling the request.');
```

Declined, citing that line. The reply matters as much as the decision — a bare "no"
reads as resistance, while the quoted source makes the reason checkable in seconds.

The general form: before editing any line, know whether you are its author or its
witness. Prose you wrote is yours to improve; recorded output is not.

### Check whether the literal fix is complete before applying it

A correct diagnosis does not guarantee a sufficient remedy. A reviewer sees the line
they commented on, not the rest of the mechanism — so applying the suggestion exactly
as written can leave a half-change that is worse than the original.

**Real case:** a comment correctly objected to `time()` in a test-setup example as
non-deterministic and asked for a fixed instant. Applying that to the shown line alone
would have frozen the clock the code reads while the fixtures around it still came
from `time()` — putting the two years apart and failing every assertion as expired. A
rare flake would have become a certain failure. The fix that works pins **one**
constant and drives both from it.

Trace the suggested change through the code it touches before committing to it. When
it turns out to be incomplete, say so in the reply and describe what you did instead —
that is the part a reviewer cannot see, and the reason to prefer it over the literal
reading.

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

### A clean auto-merge can drop lines neither side deleted

The previous section is about files. The same silence applies *inside* a file: where
both sides rewrote overlapping regions, git may resolve the hunk in one side's favour
and report nothing. Entries the other side had are then simply gone, with no conflict
marker to notice.

```bash
# After every merge, read what came out of the files both sides touched
git diff --numstat HEAD -- composer.json package.json   # unexpected churn?
git show HEAD:composer.json | jq -S '.["require-dev"]' > /tmp/before.json
jq -S '.["require-dev"]' composer.json | diff /tmp/before.json -
```

**Real case:** a merge of an 82-commit `develop` into a long-lived branch resolved
`composer.json` without conflict — and dropped two `require-dev` entries the branch had
added. One of them registered a PHPStan extension, so the analysis would have run
against a baseline generated *with* that extension while no longer loading it. Nothing
in the merge output mentioned either package.

### Choosing a side resolves the signature, not the body

When several conflicts share a shape, it is tempting to resolve them with one rule —
"their change is a subset of ours, take ours". The rule is about the *conflicting lines*;
whether it holds depends on code that is **not** in the conflict.

The recurring trap is a parameter whose nullability changed:

```php
// theirs — a minimal deprecation fix
public function f(?int $max = null)
// ours — went further, and looks like a superset
public function f(int $max = 0)

// …but the body, untouched and outside the conflict:
$max = (int)($max ?? end($allLtsVersions) ?: 0);   // ?? is now dead, $max stays 0
```

**Real case:** six conflicts of exactly this shape, resolved with one rule. Four were
right. In the other two the branch had tightened `?Type $x = null` to a non-null
default while the body still tested for null — one silently returned an empty version
range, the other resolved a path to `/` instead of the repository root. Both had been
failing for months; the merge preserved them.

After resolving by side-selection, read the body of every function whose signature you
just decided on, and check the callers of any method whose parameters were reordered —
positional call sites do not conflict and do not warn.

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

## Contributing to a Repo You Do Not Own

Before opening the PR, run the target repo's own contribution gate — all of it, from its `CONTRIBUTING.md`, not the subset that resembles your usual one. Their checklist is the review contract, and the items that look like boilerplate are the ones that fail.

```bash
gh api repos/OWNER/REPO/contents/CONTRIBUTING.md --jq '.content' | base64 -d
```

Then actually run each item. Two that are routinely skipped and routinely red:

- **The whole-tree analyzer, not the package you touched.** `staticcheck ./...`, `go vet ./...`, `phpstan analyse` at the configured level — scoping it to your directory hides failures your change caused elsewhere.
- **The spell checker.** Repos running cspell in CI usually set `incremental_files_only: true`, so it checks exactly the files your PR touched — a domain term absent from the project dictionary fails the build on a doc-only change. Run it before pushing, and add the word to the project word list using the repo's own tooling rather than rewording to dodge it.

Check `SECURITY.md` before filing anything security-flavoured as a public issue. Many projects route vulnerabilities to a private address, so a public issue is both wrong and unwelcome — and this applies to a finding you were going to *mention* in a PR body too.

Match the repo's commit conventions exactly: Conventional Commits type and scope, sign-off, signature, and any attribution trailer their `CONTRIBUTING.md` requires. A commit-message linter is a pre-commit hook in many repos and will reject the message locally before CI ever sees it.

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

### A stacked PR loses its approvals the moment its base merges

Stacking — PR B opened against PR A's branch so B can build on text or code that exists only there — is the right shape when B has no anchor without A. GitHub retargets B to `main` automatically when A merges, which is the point of the pattern. What it also does is **dismiss every review on B**, because the base changed:

```
reviews : github-actions=DISMISSED   decision=REVIEW_REQUIRED
```

Nothing about B changed. Its head SHA is the same, its checks are still green, no file moved. But `REVIEW_REQUIRED` is a host gate, not advice, so B cannot merge until an approval lands on that head again — and an automated approver only reruns on a new head. The recovery is to give it one, with the plain (merging) form of the command in [Updating a PR branch without a local clone](#updating-a-pr-branch-without-a-local-clone--gh-pr-update-branch---rebase):

```bash
gh pr update-branch $PR --repo $OWNER/$REPO
```

That merges the now-advanced base into B, which re-triggers CI **and** the approval workflow. Budget the full check matrix again, not a re-check.

Note the difference in *why* you reach for it. That section's caution is that `--rebase` force-updates and *can* reset approvals; here the approvals are **already** gone before you touch anything, dismissed by the retarget itself, and the update is what restores them.

Two things follow when you plan a stack:

- **Expect the second CI run.** The stack saves you a conflict, not a pipeline. If B's diff would conflict only trivially with A, opening B against `main` and resolving once may be cheaper than a retarget plus a full rerun.
- **Merging the base advances `main`, so the child may now conflict.** The retarget makes B's *diff* correct, not its *tree*: anything both PRs touched — a shared `CHANGELOG.md` "Unreleased" section is the usual one — conflicts on the update-branch. Resolve it there; do not merge the base into the child while the child is queued.

Observed 2026-08-13 on netresearch/t3x-nr-llm#759, stacked on #758 for a documentation anchor that existed only on that branch.

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

### Two independent PRs needing the same hunk — make it byte-identical

When two PRs split out of one piece of work both need the same addition (a
`catch` block both paths now reach, an enum case both use, the same import),
there are three options and only one of them is good:

| Approach | Cost |
|---|---|
| Stack the second PR on the first | Second PR can no longer merge on its own |
| Put the hunk in one PR only | The other PR is broken until that one lands — a merge-order trap |
| **Put the identical hunk in both** | **Git merges it once, in any order** |

Git treats the same change at the same place as *one* change, so both PRs merge
cleanly and the hunk appears exactly once in the result. That removes the
ordering constraint entirely, which matters because maintainers merge in
whatever order they review.

It only works if the text matches **byte for byte** — same wording, same
indentation, same position, and the same import placement (run the project's
formatter in both branches, or the import sorter will reorder one of them). Copy
it mechanically rather than retyping, and compare the two extracts. `<first-line>`
and `<last-line>` are the first and last lines of the hunk, used as `sed`
address patterns:

```bash
git show <other-branch>:<path> | sed -n '/<first-line>/,/<last-line>/p' > /tmp/hunk
diff <(sed -n '/<first-line>/,/<last-line>/p' <path>) /tmp/hunk && echo identical
```

Then prove the property instead of assuming it — merge every order in a
throwaway clone and check the result. Abort the run on the first conflict:
continuing would leave the repo mid-merge and every later result meaningless.

```bash
git clone -q --shared <bare-repo> /tmp/mergetest && cd /tmp/mergetest
for order in "<branch-A> <branch-B>" "<branch-B> <branch-A>"; do
  git reset -q --hard <base>
  for b in $order; do
    git merge -q --no-edit "$b" || { echo "CONFLICT: $b in order [$order]"; git merge --abort; exit 1; }
  done
done
# counts matching LINES, so use one distinctive line of the hunk, not the hunk
grep -cF '<one distinctive line of the hunk>' <path>   # must be 1, not 2
```

State in both PR bodies that the hunk is identical and why, so a reviewer does
not "clean up" the duplicate in one of them.

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

### A series of sibling branches: rebuild append-only sections, don't merge them

When several of your own branches wait on one another, each needs `main` merged
in again after the previous one lands. For an **append-only** section — a
CHANGELOG's `[Unreleased]`, a toctree, an index — the second and later merges of
that series behave differently from the first, and a resolver that works on the
first silently corrupts the rest.

The trap is any resolver whose premise is *"ours holds only my additions"* —
fold-ours-into-theirs, `git checkout --ours` on a hunk, a script that appends one
side to the other. That premise holds for the first merge only. Afterwards
"ours" already contains everything the previous merge brought in, so each round
appends `main`'s entries **again**. There are no conflict markers, the diff looks
plausible, and the damage is visible only by counting: five branches merged in
sequence produced ten `[Unreleased]` bullets standing three and four times over,
and two of the PRs carried it to `main` before anyone noticed.

Rebuild instead of merging. Take *theirs* (current `main`) verbatim, lift your
own block out of *ours* by a distinctive first line, and insert it under the
existing heading:

```bash
git show :3:CHANGELOG.md > /tmp/theirs.md   # current main
git show :2:CHANGELOG.md > /tmp/ours.md     # your branch
# extract your block from ours, insert into theirs under the matching heading
```

Then assert before committing — the three checks that catch every variant of
this failure:

- the heading count is unchanged (no second `### Added`),
- your block appears exactly once, above the newest released section,
- no top-level bullet's first line occurs twice in the section.

The same three assertions find it after the fact, which is how the duplication
above was eventually caught.

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

Two different causes produce this message: the tracking ref moved (below), or there is no tracking ref at all (the subsection after it). Neither is a reason to escalate to plain `--force`.

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

#### When the push target is a URL, not a remote

Fetching does not help — and cannot — if the push names a URL:

```bash
git push --force-with-lease git@github.com:me/repo.git HEAD:my-branch
# ! [rejected]  HEAD -> my-branch (stale info)
```

A URL has no remote-tracking ref, so the lease has nothing to compare against and the push is rejected every time, however recently you fetched. This is not the safety check catching a real race; it is the check with no input. Typically hit when pushing to a fork that was never added as a remote — `gh repo fork --clone=false` creates the fork on the server but adds nothing locally.

Add the remote once, fetch it, then push to it by name:

```bash
git remote add fork git@github.com:me/repo.git
git fetch fork
git push --force-with-lease fork HEAD:my-branch
```

`git remote -v` before force-pushing is the cheap check: if the target is not listed there, the lease cannot work. Do not reach for plain `--force` — that discards the protection instead of supplying it.

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

## A Green Job Is Not a Green Test Run

Job status answers "did the command exit 0". It does not answer "did the tests pass".
Where a pipeline publishes a test report, read it — the two disagree more often than
they should, and the report is the stronger statement.

```bash
# Same placeholders as the GitLab section below: GITLAB_HOST, $P the URL-encoded
# project path or numeric id, $TOKEN a PRIVATE-TOKEN.
export GITLAB_HOST=git.example.com

# GitLab: the report, not just the job list
curl -s -H "PRIVATE-TOKEN: $TOKEN" "https://$GITLAB_HOST/api/v4/projects/$P/pipelines/$PIPELINE/test_report" \
  | jq '{total_count, failed_count, suites: [.test_suites[] | {name, failed_count, total_count}]}'

# GitHub: the rollup hides startup failures entirely — see the section below
gh run list --repo "$R" --commit "$SHA" --json name,status,conclusion
```

Two ways a check stops being a gate without anyone noticing:

- **The command mutates instead of checking.** A job running `php-cs-fixer fix`
  (rather than `fix --dry-run`) repairs the files in the container, throws them away
  with it, and exits 0. Every repaired file is recorded as a failed case in the JUnit
  report while the job is green. One project had run that way for three and a half
  years — 30 standing violations, a permanently green gate, and the evidence expiring
  with the artifact about an hour after each run.
- **Nothing is enforced because nothing fails.** `allow_failure: true` (GitLab) and
  non-required checks (GitHub) are legitimate, but they make the pipeline's colour a
  poor summary. Before reading a pipeline as approval, list which jobs can actually
  block:

```bash
curl -s -H "PRIVATE-TOKEN: $TOKEN" "https://$GITLAB_HOST/api/v4/projects/$P/pipelines/$PIPELINE/jobs" \
  | jq -r '.[] | select(.allow_failure == false) | "\(.status)  \(.name)"'
```

When a report's numbers look implausible — everything failing, or nothing at all —
check the artifact before believing it. An expired or never-collected JUnit artifact
reports `total_count: 0`, which reads like "no failures" and means "no data".

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

### A parallel-merged config PR turns your green check red on main

The second way PR-green diverges from main-green needs no `push:`-gated job: a PR's lint/analysis runs are pinned to the **config on the PR branch**, and a sibling PR that adopts a stricter shared config (rector/eslint/phpstan rule sets) can merge between your last CI run and your merge. Both PRs are green in isolation; the merge result on `main` fails the very check both passed. Nothing lied — the config changed under you.

- Real case (2026-08-04, t3x-nr-vault): PR A was rebased and merged in parallel with PR B ("adopt the shared org rector config", which added `NewlineAfterStatementRector`). PR A's green Rector run predated that config; `ci / Rector` went red on `main` over one missing blank line. Recovery was a one-line fix-forward PR.
- Rebasing before merge does **not** close the window — the config PR can land after your rebase. Only a merge queue or a "require branches to be up to date" rule makes it structurally impossible; where neither is on, expect this occasionally on active repos.
- Consequence: watching the post-merge run on `main` is part of the merge, because this failure class is visible nowhere else. When it fires, diff `main`'s history for config-touching merges since your branch's last CI run and fix forward against the new config — it is mechanical, not an investigation into which check was wrong.

### Stacked PRs: retarget before you merge, `--delete-branch` only at the end

A stacked chain (PR2 based on PR1's branch, PR3 on PR2's, …) merges
bottom-up — but two GitHub behaviours break the naive loop:

1. **`gh pr merge --delete-branch` on a stacked base CLOSES the child PR.**
   GitHub's automatic retargeting of dependent PRs is unreliable: when the
   base branch disappears, the child can be closed instead of retargeted to
   the default branch (observed 2026-08-01: child PR closed mid-stack, its
   base still pointing at the deleted branch).
   Recovery, if it happens: re-push the deleted base branch (the local copy
   still has it), `gh pr reopen <CHILD_NUMBER>`, then
   `gh pr edit <CHILD_NUMBER> --base main` — the base of a *closed* PR cannot
   be edited, so reopen first.
2. **`mergeStateStatus` needs time and only `CLEAN` is trustworthy.** After a
   retarget it cycles through `UNKNOWN`/`BLOCKED`/`UNSTABLE` before settling.
   `UNSTABLE` means a **non-required** check is failing — decide explicitly
   whether that is acceptable; a merge gate that requires `CLEAN` treats it
   as blocked.

The robust bottom-up sequence for each child after its parent merged:

```bash
gh pr edit <CHILD_NUMBER> --base main    # retarget FIRST, while everything is open
# wait until mergeStateStatus == CLEAN   # separate step — state recomputes async
gh pr merge <CHILD_NUMBER> --merge       # NO --delete-branch mid-stack
# verify: git ls-remote origin main  ==  the PR's mergeCommit.oid
```

Delete all stack branches in one pass **after the last PR merged** (a repo
with "automatically delete head branches" usually does it for you).

#### GitHub-native stacked PRs: merge the tip, not each PR in turn

The sequence above is for a **hand-built** chain. GitHub's native Stacked PRs
feature (public preview, `gh stack`) behaves differently and the difference is
the whole point of using it: **merging the top PR merges every PR beneath it in
one operation.** Walking the stack bottom-up there is not merely slower — on a
merge-queue repo it is actively worse, because each PR costs its own queue cycle
and the queue's merge-correctness validation rejects two chained entries that are
in flight at the same time ("invalid changes in the merge commit").

```bash
gh pr merge <TIP_NUMBER> --merge --auto     # the whole stack lands
```

Verify containment before assuming a lower PR is covered, rather than reading it
off the UI:

```bash
git merge-base --is-ancestor "$(gh pr view <LOWER> --json headRefOid --jq .headRefOid)" \
                             "$(gh pr view <TIP>   --json headRefOid --jq .headRefOid)" \
  && echo "LOWER is contained in TIP"
```

Observed 2026-08-09 (netresearch/t3x-nr-llm): merging only #665 landed #663, #664 and #665 together; the preceding attempt to queue all three separately was rejected by the queue three times. The PRs that were merged this way close as
`MERGED`; PRs whose commits reach `main` through a *different* PR (see batching,
below) close as `CLOSED` and need their issues closed by hand.

One preview-era caveat worth knowing before relying on it: deleting a lower
branch can **close** the PR above it rather than retarget it, and a closed PR of
this kind cannot be reopened. Leave `--delete-branch` off until the stack is
fully merged.

Related: a workflow **rerun executes the frozen merge commit** — it does not
re-resolve `refs/pull/N/merge` against the moved base. A check that depends
on base state (template drift, conflict detection) stays wrong after main
moved; push a base-merge into the PR branch instead of rerunning.

### Many independent PRs, one queue: batch them into an integration branch

A merge queue serializes by design, so N ready PRs cost N queue cycles — and if
they all touch one accumulating file (`CHANGELOG.md`, a docs index), each merge
also invalidates the next one's merge commit, so every PR needs a forward-merge
before its turn. Thirteen PRs took several hours this way and merged one per
hour at best.

When the PRs are genuinely independent, merge them locally into one integration
branch and send that through the queue instead. Two cycles replaced thirteen
(netresearch/t3x-nr-llm#685 with ten PRs, #686 with three chain tips, both
2026-08-09).

```bash
git -C .bare worktree add ../integration -b integration/batch-$(date +%F) origin/main
cd ../integration
for pr in 648 653 676 677; do
  git merge --no-edit "$(gh pr view $pr --json headRefOid --jq .headRefOid)"
done
```

Four things decide whether this pays off, and skipping any of them costs more
than the batching saved:

- **Resolve the accumulator files once, deliberately.** The conflicts are almost
  always confined to append-only files. Auto-resolving them by keeping *both*
  sides works for the content but **duplicates entries and flattens section
  assignment** when the same entry was reworded on both sides — verify the
  merged file afterwards (count entries, check for duplicates) instead of
  trusting the resolver. Anything outside that known set is a real conflict:
  stop and resolve it by hand.
- **Run the full gate on the integration branch, not on the individual PRs.**
  Combination breaks exist that no single PR can show: a constructor argument
  another PR makes mandatory, two PRs extending the same factory differently.
  Three such breaks appeared across two batches here — all invisible per-PR,
  all caught by the batch gate.
- **Prove containment before closing anything.** `git merge-base --is-ancestor
  <pr-head> origin/main` per PR, after the batch merges. This is the only
  evidence that a PR's work actually landed.
- **The batched PRs close as `CLOSED`, not `MERGED`,** so GitHub does not run
  their `Closes #N` keywords. Close those issues explicitly and say which PR
  carried them, or the backlog silently keeps them open.

Do not batch PRs that are chained (a stack) — merge the tip instead, see above.

### Follow-up pushes to an armed PR branch: confirm the PR is still OPEN

Once auto-merge (or a queue) is armed, a fast merge plus branch auto-delete can
land the PR before your follow-up commit does. `git push` to the deleted branch
then silently **re-creates it** — off a now-stale base, with your commit
dangling and no PR attached; nothing errors and nothing merges.

Before pushing any follow-up to an armed branch, confirm the PR is still open:

```bash
gh pr view NUMBER --json state --jq '.state'   # must print OPEN
```

Any other state (`MERGED`, `CLOSED`) is a stop signal: put the follow-up on a
fresh branch off updated main and open a new PR. If a dangling re-created
branch already exists, delete it and rescue the commit via cherry-pick.

### Auto-Merge / Merge-Queue Arming Gate

`gh pr merge --auto` is a **deferred merge with no human in the loop** — and a
merge queue only re-runs *required checks*; it does **not** wait for review
threads, bot reviews in flight, or Sonar-style informational checks. Arming at
PR creation therefore merges over unaddressed review feedback the moment CI is
green.

Arm auto-merge / enqueue **only when all four hold**:

1. **Zero unresolved review threads** (GraphQL `reviewThreads`, not the UI).
2. **All checks green** — including non-required ones you intend to honor.
3. **No pending review request** (`gh pr view --json reviewRequests` is `[]`)
   — a re-requested bot review that has not landed yet counts as pending.
4. **A quiet runner pool** — see below.

**Do not enqueue into a busy runner pool.** A merge queue drops an entry whose
required checks do not report within `check_response_timeout_minutes` (default
5). That clock starts at enqueue and covers the wait for a *runner*, not just
the run: with the pool saturated, the jobs sit in `queued` with no runner and
the entry is discarded having executed nothing.

Retrying makes it worse. Each attempt spawns a full set of runs on a
`gh-readonly-queue/*` branch, and a dropped entry **does not cancel them** — so
every retry leaves more runs holding slots and slows the next attempt. In
netresearch/ofelia this piled up 18 unfinished runs and turned a four-attempt
loop into a guaranteed failure, while the same required checks concluded in
**2.0 minutes** in PR context, well inside the window.

**Tell a busy pool from a slow one before deciding.** `queued` and
`in_progress` are different states and the API reports them separately;
collapsing both into "pending" reads as "CI is running" when in truth no runner
has picked anything up. `pr-status.sh` keeps them apart — the checks line shows
`N pending (X running, Y queued)` — and answers `await-capacity` instead of
`wait` when a *required* check is queued while nothing at all is running. That
is the precondition for the paragraph above: enqueueing in that state is what
gets the entry dropped.

The concurrency limit itself is not readable. `GET /orgs/{org}/actions/hosted-runners/limits`
answers `404 "GitHub hosted runners are not supported for this organization"`
outside the larger-runner product, and the per-plan ceiling for standard runners
exists only in the documentation. So do not try to compare against a number —
observe the state instead: required checks queued with zero running is
sufficient on its own, and needs no knowledge of the plan.

Gate on it instead: enqueue when the repo has at most ~2 unfinished runs.

```bash
gh run list --repo "$R" --limit 25 --json status \
  --jq '[.[]|select(.status!="completed")]|length'
```

Done that way, three consecutive PRs merged on the first attempt after one had
been thrown out four times from a loaded pool. If an entry still drops on a
quiet pool, the timeout is genuinely too short — read it rather than retrying:

```bash
gh api "repos/$R/rules/branches/main" \
  --jq '.[]|select(.type=="merge_queue")|.parameters'
```

Before that one retry, cancel your own orphaned queue runs — only your PR's,
since other PRs thrash the same way and their runs are not yours to kill:

```bash
gh run list --repo "$R" --limit 40 --json databaseId,status,headBranch \
  | jq -r --arg p "gh-readonly-queue/main/pr-$PR-" \
      '.[] | select(.status != "completed")
           | select(.headBranch | startswith($p)) | .databaseId' \
  | xargs -r -n1 gh run cancel --repo "$R"
```

Bot reviews (Copilot, Gemini) land 2–5 minutes after each push — wait that
window out before concluding "no threads".

**A cancelled run leaves rows behind, and they are not failures.** When a push
supersedes a run, its jobs conclude `CANCELLED` and those check-runs stay on the
*earlier* commit forever. Where a workflow's `name:` is an unevaluated
expression they are doubly confusing, showing up as rows literally called
`e2e / matrix.typo3 != '' && …`. `pr-status.sh` splits them: a cancelled context
that later reported under the same name is counted as **stale** and dropped from
the numbers, while one that never reported again still shuts the gate and is
listed under `cancelled — re-run, do not debug`. Before this split, two stale
e2e rows read as `2 fail` with `NEXT: fix-ci` on a pull request GitHub itself
called `CLEAN`, which cost an hour of log archaeology on a run that had been
cancelled on purpose.

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

The push rejection is a **protected-branch hook**, not a permissions problem:

```
remote: error: GH006: Protected branch update failed for refs/heads/<branch>.
remote: - A pull request for this branch has been added to a merge queue.
remote:   Branches that are queued for merging cannot be updated.
```

Note the mutation input field is `id:`, not `pullRequestId:` — the latter fails
with `InputObject 'DequeuePullRequestInput' doesn't accept argument`.

**An enqueued PR still reads as `CLEAN`, so "clean, go merge" is the wrong
verdict.** `mergeStateStatus` describes the branch, not the queue: a PR sitting
in the queue keeps answering `CLEAN` with every check green and no open thread,
which is exactly what a merge-readiness check looks for. Ask the PR itself
whether it is already in line:

```bash
gh api graphql -f query='{repository(owner:"OWNER",name:"REPO"){
  pullRequest(number:NNN){ mergeQueueEntry{ state position estimatedTimeToMerge } }}}'
```

`mergeQueueEntry` is null unless this PR holds an entry; when it does, it
carries `position`, `state` (`QUEUED`, `AWAITING_CHECKS`, `MERGEABLE`,
`UNMERGEABLE`, `LOCKED`) and an ETA in seconds. The repo-level signal — a
`merge_queue` ruleset exists — answers a different question and cannot stand in
for it. `pr-status.sh` reports both, as `queue=` and an `in queue` line, and
answers `wait` rather than `merge` while an entry is held; `pr-merge.sh`
refuses on that same verdict. Enqueueing an entry that already exists only
restarts its checks and pushes the merge further out.

**`--delete-branch` is rejected while a merge queue is enabled.** `gh pr merge`
fails outright with:

```
Cannot use -d or --delete-branch when merge queue enabled
```

This is a hard error, not a warning: the merge does not happen. In a batch
merge loop the flag silently costs a full round per PR — four rounds were burned
on it in one rollout before the message was read. Drop `--delete-branch` from
any script that merges across repos where some enable a queue, and let the
repo's own "automatically delete head branches" setting handle cleanup. Passing
a merge-method flag (`--merge` / `--rebase`) is likewise pointless once a queue
owns the branch; it responds with `The merge strategy for main is set by the
merge queue`.

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

### "Never merge Dependabot/Renovate by hand" presumes a deps workflow exists

Leaving bot PRs alone is right *because* an auto-merge workflow lands them once
they are green. Where no such workflow is installed, the rule has no mechanism
behind it and simply strands the PRs. One repo in a sweep carried **12 open bot
PRs** — including a `tar` security update sitting `CLEAN` and untouched for five
weeks — because its `.github/workflows/` held only `ci.yml` and a publish
workflow.

Check for the mechanism before deferring to it:

```bash
gh api "repos/$R/contents/.github/workflows" --jq '.[].name'
```

- **A deps auto-merge workflow exists** → the rule applies. Do not merge by
  hand; bring the PR green and let the workflow land it. If it is green and
  still open, the workflow ran before the checks passed — re-run it rather than
  merging (`gh run rerun <id>` on that workflow's run for the PR's head SHA).
- **No such workflow** → the rule does not apply. Merging bot PRs by hand is not
  forbidden, it is simply unautomated: report the stranded PRs and the missing
  automation instead of leaving them to rot. Flag security updates and majors
  separately — a `tar` advisory fix and a `jest` v30 major do not carry the same
  risk and should not be swept together.

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

**A pending auto-merge request silently swallows the enqueue.** The converse of
the note above, and the more expensive one: when an auto-merge request *is*
attached to the PR, `gh pr merge <n> --repo <r> --merge` on a merge-queue
repository prints its usual success line and **exits 0 while adding nothing to
the queue**. Measured on one PR: immediately after the call `isInMergeQueue` was
`false` and the queue was empty; after `gh pr merge <n> --repo <r>
--disable-auto` the identical call put it at position 1. Nothing shows the
failure — `gh pr checks` is green, `mergeStateStatus` stays `CLEAN`, no timeline
event is written, and the shell sees a zero exit — so a driver that trusts the
exit status reports "queued" for a PR that will never merge. This cost several
hours of misdiagnosis before the queue was read back. Two habits follow: never
report an enqueue you have not read back, and check `autoMergeRequest` first
when a queue entry fails to appear.

```bash
gh api graphql -f query='{repository(owner:"OWNER",name:"REPO"){
  pullRequest(number:NNN){ state isInMergeQueue
                           autoMergeRequest{ enabledBy{ login } } }}}'
# state MERGED                        -> it landed.
# isInMergeQueue true                 -> really queued.
# neither, autoMergeRequest non-null  -> the request swallowed it: --disable-auto, then retry.
```

`pr-merge.sh` does exactly this after every merge call, polls a few seconds for
the entry to register, and exits 2 with the `--disable-auto` remedy rather than
claiming an enqueue that did not happen. It reports only — clearing someone
else's auto-merge request is a caller decision, not a side effect of asking to
merge.

### Signing Readiness (Preflight — Before Committing)

Two failures hide behind "signing is broken", and they surface at opposite ends of the run. A **local** signing failure surfaces immediately: `git commit -S` aborts and the branch does not move. A **host** verification failure — the key signs fine but GitHub does not recognise it — surfaces only at the *merge gate* (BLOCKED on DCO / "verified signatures"), i.e. **after** all the work is committed and pushed, forcing a full re-sign cycle. Preflight both before a commit-heavy run (e.g. `/pr-finish`): confirm a signing key is actually available and that `git commit -S` will sign, rather than assuming it.

```bash
scripts/signing-preflight.sh     # exit 0 READY · 1 NOT READY · 2 could not probe
```

`signing-preflight.sh` is the mechanical form of everything below: it probes on a throwaway branch through a temporary index (so a staged change is never swept into the probe commit), asserts on the commit object, retries once with `--no-verify` to tell a hook rejection apart from a signing failure, and removes the branch either way. `--check-commit <rev>` answers the same question for an existing commit, `--config-only` reports the config without committing. Its regression suite is `tests/test_signing_preflight.sh`; checkpoint GW-17 applies the same rule to a repository being assessed.

By hand, where the script is not available:

```bash
# SSH-signing setups: is a key the agent can sign with actually loaded?
ssh-add -l        # "no identities" → signing (and any SSH git auth) will fail until re-added
# Definitive probe: a throwaway signed commit carries a signature, then drop it —
# on a throwaway branch, not on `main` (see commit-conventions.md, "Verify signing capability without committing on `main`")
git switch -c tmp/sign-probe
# conventional msg — a commit-msg hook rejecting `probe` aborts the commit and reads as a signing failure
git commit -S --allow-empty -m "chore: signing probe" \
  && (git cat-file commit HEAD | sed -n '/^$/q;p' | grep -qE '^gpgsig(-sha256)? ' && echo "SIGNING READY" || echo "SIGNING NOT READY") \
  || echo "SIGNING NOT READY — commit failed"
git switch - && git branch -D tmp/sign-probe
```

**Assert on the commit object, not on local verification.** `git log --show-signature` / `%G?` answer the narrower question "can *this machine* verify the signature", and report failure on setups that sign perfectly well. With `gpg.format=ssh` and no `gpg.ssh.allowedSignersFile`, `git log --show-signature -1` prints `error: gpg.ssh.allowedSignersFile needs to be configured and exist for SSH signature verification` and then `No signature`, and `%G?` returns `N` — on a commit that carries a valid signature and that the host reports as `verified: true` once the key is registered as a signing key. The command still **exits 0** while printing that error, so a driver reading `$?` sees success too.

`N` is indistinguishable from genuinely unsigned, which makes it more dangerous than the `E` case in *Signature verification: the GitHub API is the source of truth, not your keyring* above — `E` at least reads as "could not check here". Setting `gpg.ssh.allowedSignersFile` flips that same unchanged commit to `Good "git" signature` / `%G? = G` (measured on git 2.54.0), which is the fix if you also want local verification to work.

The `gpgsig` header depends on no verification config and is written by both backends (`-----BEGIN SSH SIGNATURE-----` under `gpg.format=ssh`, `-----BEGIN PGP SIGNATURE-----` under GPG), so it answers exactly what the preflight asks: did `git commit -S` produce a signature. Cut the header at the first blank line (`sed -n '/^$/q;p'`) — matching `^gpgsig` against the whole object also matches a message *body* line starting with `gpgsig`, and reports an unsigned commit as signed.

**Do not assert on `Good` either.** Unanchored, it matches the `Author:` line, so an unsigned commit by an author named e.g. "Goodwin" reports `SIGNING READY`. And a local `Good` only proves your own allowed-signers file accepts your key, never that GitHub does — that is the `unknown_key` API check under *Signing and DCO Failures* below. **Keep the commit chained to the check with `&&`.** `git commit -S` cannot silently produce an unsigned commit: with a key it cannot load it aborts (`fatal: failed to write commit object`, exit 128, HEAD unmoved). But an unchained check then reads the *parent* commit, which in signed history carries its own `gpgsig` header — so it prints `SIGNING READY` for a probe that never happened.

If the probe fails (no askpass, a locked/dropped key, or an unloadable `user.signingkey`), resolve it **before** doing the work — the mid-run remedy is the same `rebase --exec` re-sign as a reactive failure, but you avoid discovering it at the gate. `commit failed` is not by itself a signing verdict: a `commit-msg` hook rejecting the probe message aborts the commit exactly the same way, so read the commit output before chasing keys. See *Signing and DCO Failures* below for that remedy.

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

For automated enforcement at tool-invocation time, see the `merge-gate.sh` hook recipe in `references/claude-code-hooks.md`. The hook enforces the **runtime-checkable subset** — `mergeStateStatus` and unresolved thread count — which covers the most common block reasons. It deliberately does not gate on `reviewDecision`: repos without a required-approval rule report `reviewDecision` "" and merge legitimately when CLEAN, so that gate would false-positive-block them; `mergeStateStatus == CLEAN` already encodes any required-approval rule. Signed-commits and CI-annotations checks are not enforced by the hook (annotations in particular require the commit-level API call above); rely on the repo's branch-protection rules and local pre-commit hook for those.

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

#### Is that red check actually blocking? `isRequired` is the only answer

A failing check is not automatically a blocker, and neither `gh pr checks` nor
`statusCheckRollup` says which ones the base branch requires — so a red
non-required check gets chased for nothing while the real blocker stays
invisible. `isRequired(pullRequestNumber:)` on the rollup contexts answers it
directly, and unlike `repos/{owner}/{repo}/rules/branches/BASE` it does not need
permissions that a token may lack:

```bash
gh api graphql -f query='
{ repository(owner:"OWNER", name:"REPO") {
    pullRequest(number:NUMBER) {
      mergeable mergeStateStatus
      commits(last:1){nodes{commit{statusCheckRollup{contexts(last:100){nodes{
        ...on CheckRun{name conclusion isRequired(pullRequestNumber:NUMBER)}
        ...on StatusContext{context state isRequired(pullRequestNumber:NUMBER)}}}}}}}
    } } }' --jq '
  [.data.repository.pullRequest.commits.nodes[0].commit.statusCheckRollup.contexts.nodes[]
   | select(.isRequired==true) | "\(.name // .context) = \(.conclusion // .state)"] | .[]'
```

A `null` in that output is a required check still running — that, not the red
one, is what `BLOCKED` is waiting on. Observed 2026-08-09
(netresearch/t3x-nr-llm#687): `copilot-pull-request-reviewer` was red for the
whole run and never appeared in the required list; the PR merged on it. Note the
number is passed twice — once to `pullRequest(number:)` and once to each
`isRequired(pullRequestNumber:)`; omitting the second yields a schema error, not
a default.

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

### "Can I contribute here?" is a flag lookup, not an inference

Before concluding that a project takes issues, forks or merge requests only from
members, read the project's own capability flags:

```bash
curl -s -L -H "PRIVATE-TOKEN: $TOKEN" "https://$GITLAB_HOST/api/v4/projects/$P" \
  | jq '{issues_enabled, merge_requests_enabled, forking_access_level, permissions}'
```

Two traps sit on that call:

- **Anonymous requests null the flags.** Without a token the same fields come
  back `null`, which reads like "disabled" and means "not visible to you". Only
  an authenticated answer distinguishes the two.
- **Follow redirects.** Instances reachable under two hostnames answer the API
  on one of them; without `-L` you get a `307`/`404` and may conclude the project
  or its API does not exist.

Do not substitute observation for the flags. "The last 20 MRs all came from
in-repo branches" is consistent with forks being forbidden *and* with nobody
having needed one — a project whose `forking_access_level` is `enabled` will
show exactly the same history if all its contributors are members. Likewise, an
`open_issues_count` you cannot read is not an absent tracker.

The flags also separate two failure modes that look identical from outside: a
project that refuses outside contributions, and an account that may not create
projects (`Limit reached — You cannot create projects in your personal
namespace`). The first is a policy to respect; the second is a permission to
request, and saying which one blocks you is the difference between a useful
report and a shrug.

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

**The merge itself is asynchronous** — the command returns before the target
branch has moved. A `git pull` fired right after races the server-side merge
and can deliver the *pre-merge* tip while the MR already reports
`state=merged`; anything derived from that checkout (a release tag, a branch
cut from "main") then pins the old commit. One session tagged `v1.1.0` on the
pre-merge tip this way and the tag pipeline published an image without the
feature. Before tagging or branching off a freshly merged target:

```bash
# the remote target must equal the MR's merge commit
test "$(git ls-remote origin "$TARGET" | cut -f1)" \
   = "$(glab api "projects/$P/merge_requests/$M" | jq -r .merge_commit_sha)"
```

And never swallow the pull's outcome (`git pull --ff-only 2>&1 | tail -1`
hides a refused fast-forward) — confirm with `git rev-parse HEAD` that the
checkout actually sits on the expected commit.

### Rebase when the MR is behind

On projects with `merge_method: rebase_merge` (semi-linear history) a behind
branch IS a blocker: `glab mr merge` fails with a bare
`{message: 405 Method Not Allowed}` and the MR shows
`detailed_merge_status: need_rebase`. The light path is a server-side rebase —
no local fetch dance needed:

```bash
glab mr rebase <MR>
# poll until the status leaves need_rebase (it passes through "checking")
glab mr view <MR> --output json | jq -r '.detailed_merge_status'
```

The rebase creates a new head SHA, so wait for the freshly triggered pipeline
before retrying the merge.

On plain merge-commit projects GitLab will happily report `mergeable` while
the branch is behind the target — being behind is not a blocker there, unlike
a GitHub merge queue. If the
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
