# Merge-Gate Watcher

Canonical polling loop to drive a PR to merge once review threads are handled. Hand-rolling this per PR invites classification bugs (a soft check counted as hard ⇒ false HOLD; a missed one ⇒ premature merge).

## Driving many PRs at once

One `pr-status.sh --watch` per PR, all in parallel in one background command — each instance returns at *its* first actionable event, so a slow PR never delays acting on a fast one:

```bash
d=$(mktemp -d)   # fresh dir: no interleaved writes, no stale files from a prior run
for p in "owner/repo-a 11" "owner/repo-b 22"; do
  ( set -- $p
    pr-status.sh -R "$1" "$2" --watch | grep '^NEXT:' | tail -1 | sed "s|^|$1#$2 |" > "$d/${1//\//_}-$2" ) &
done
wait; cat "$d"/*
```

Then act per line: `NEXT: merge` → `pr-merge.sh` in a **new** invocation (merge-gate hooks evaluate at call time — never chain the wait and the merge in one command); `resolve-threads` / `address-review` → handle that PR individually while the rest keep going. Do not write a bespoke driver that re-reads PR state in a loop and dispatches on it — that re-implements `pr-status.sh` badly, waits for the one outcome it was told about, and sleeps through the rest (verified 2026-08-03: a 7-repo release sweep completed on this pattern with zero hand-rolled polling).

## Check taxonomy

Classify every failing check BEFORE reacting:

| Class | Examples | Reaction |
|-------|----------|----------|
| **Hard** | unit/integration/E2E tests, lint, build | HOLD and fix — except known infra flakes (Docker Hub pull timeout, buildx setup): one `gh run rerun <id> --failed` |
| **Soft, self-healing** | `codecov/*` while sibling jobs still run (partial uploads) | Ignore while `pending > 0`; if persisting after completion: one full `gh run rerun <id>` |
| **Soft, structural** | SonarCloud PR gate on refactor PRs | Introspect before deciding (below) |

## One shard red in a sharded suite: flake vs. real regression

When one of N test shards fails, read its **first** error before you reach for a rerun — whether the Hard-class failure above is a flake or a real bug turns on it:

- **Infra flake** — the first error is a stack-boot / health-check line (`App failed to start within timeout`, DB-not-ready, a 5xx from the app root). Every assertion failure below it is collateral: there was no app to talk to. Only that one shard is red; the siblings pass. Reaction: one `gh run rerun <id> --failed` (a rebase + push also re-triggers a clean run).
- **Real regression** — *typically* the same spec(s) fail **across all shards deterministically**, and the first error is an assertion (or an actionability timeout), not a boot line. A regression in shared code does not politely confine itself to one shard. (The Playwright case below is the exception — a real regression that can surface on a single shard.)

Playwright tell: `locator.check` / `locator.click: Test timeout` is an **actionability** failure — the element never became visible / stable / hit-testable — usually a CSS or DOM change that broke a hit target. Treat it as a real regression to investigate even when it surfaces on a single shard, not as a flake to rerun. (Seen: a `.field-check-row` restyle moved a label out of the node a spec located by, so `getByText`-anchored `.check()` hung 30s — red on shard 1 only, looked exactly like a boot flake, was a real DOM regression.)

## Sonar gate introspection

Never merge on a red Sonar gate without knowing *why* it is red:

```bash
AUTH="Authorization: Bearer $SONAR_TOKEN"
curl -s -H "$AUTH" "https://sonarcloud.io/api/qualitygates/project_status?projectKey=$KEY&pullRequest=$PR" \
  | jq -r '[.projectStatus.conditions[]|select(.status!="OK")|.metricKey]|join(",")'
curl -s -H "$AUTH" "https://sonarcloud.io/api/issues/search?componentKeys=$KEY&pullRequest=$PR&resolved=false&ps=1" | jq .total
```

Merge-despite is defensible only when the sole failing condition is a touched-line **re-attribution** metric, open PR issues are 0, and the PR body documents the rationale. Real findings: fix them.

**`new_duplicated_lines_density` is only sometimes that metric — check which case you are in before invoking the exemption.** It is re-attribution when the PR *moved or touched* existing lines and Sonar consequently charged the surrounding, already-duplicated block to the diff. It is a real finding when the PR *added* files: three new sibling classes written in one sitting are copy-paste, and the metric is measuring exactly that. `api/issues/search` cannot tell them apart — duplication is a measure, not an issue, so it returns 0 in both cases and the "open issues are 0" half of the exemption is satisfied either way.

Ask which files carry the new duplicated lines, then read the blocks:

```bash
curl -s -H "$AUTH" "https://sonarcloud.io/api/measures/component_tree?component=$KEY&pullRequest=$PR&metricKeys=new_duplicated_lines&ps=200" \
  | jq -r '.components[] | (.measures[0] | (.value // .periods[0].value // "0")) as $v
           | select($v != "0") | select(.qualifier=="FIL") | "\($v)\t\(.path)"'
curl -s -H "$AUTH" "https://sonarcloud.io/api/duplications/show?key=$KEY%3A<path>&pullRequest=$PR" \
  | jq '.duplications[].blocks | map("\(.from)-\(.from + .size - 1)")'
```

Two shapes to get right or the first command prints nothing: a **`new_*`** metric
carries its value under `periods[0].value`, not `.value`, and the response lists
directories as well as files, so filter on `qualifier=="FIL"` to get paths you
can pass to `duplications/show`.

If the files listed are ones the PR *added*, dedupe them — the exemption does not apply. `typo3-testing-skill/references/sonarcloud.md` ("Gotchas: new-code duplication") carries the same rule from the analyzer side and the recovery patterns for it.

## Watcher skeleton

```bash
R=owner/repo; PR=123; BR=branch; RERUN_DONE=0
for i in $(seq 1 100); do
  sleep 30
  STATE=$(gh pr view $PR --repo $R --json state,mergeStateStatus) || continue
  [ "$(jq -r .state <<<"$STATE")" = "MERGED" ] && exit 0
  MS=$(jq -r .mergeStateStatus <<<"$STATE")
  UNRES=$(gh api graphql -f query="{repository(owner:\"${R%/*}\",name:\"${R#*/}\"){pullRequest(number:$PR){reviewThreads(first:100){nodes{isResolved}}}}}" \
    --jq '[.data.repository.pullRequest.reviewThreads.nodes[]|select(.isResolved|not)]|length') || continue
  CHECKS=$(gh pr checks $PR --repo $R 2>/dev/null)
  PENDING=$(grep -c -E "pending|in_progress" <<<"$CHECKS" || true)
  HARD=$(grep "fail" <<<"$CHECKS" | grep -v -c -E "codecov|SonarCloud Code Analysis" || true)
  SOFT=$(grep "fail" <<<"$CHECKS" | grep -c -E "codecov|SonarCloud Code Analysis" || true)
  [ "$MS" = "BLOCKED" ] && [ "$UNRES" -gt 0 ] && { echo "HOLD: $UNRES threads"; exit 1; }
  if [ "$HARD" -gt 0 ] && [ "$PENDING" -eq 0 ]; then
    # one rerun for infra flakes only, then HOLD
    if [ "$RERUN_DONE" -eq 0 ] && grep "fail" <<<"$CHECKS" | grep -qE "E2E|Integration|docker"; then
      gh run rerun "$(gh run list --repo $R --branch $BR --workflow CI --limit 1 --json databaseId --jq '.[0].databaseId')" --repo $R --failed
      RERUN_DONE=1; sleep 60; continue
    fi
    echo "HOLD: hard fails"; grep fail <<<"$CHECKS"; exit 1
  fi
  if [ "$PENDING" -eq 0 ] && [ "$UNRES" -eq 0 ] && { [ "$MS" = "CLEAN" ] || [ "$MS" = "UNSTABLE" ]; } && [ "$HARD" -eq 0 ] && [ "$SOFT" -eq 0 ]; then
    gh pr merge $PR --repo $R --merge && exit 0
  fi
done
```

Pitfalls baked in: `grep -c` exits 1 on zero matches (`|| true`); decide hard-fail only at `PENDING -eq 0` (codecov posts transient FAILURE mid-run); never count a check class you did not explicitly list.

**On a merge-queue repo, drop the strategy flag.** `gh pr merge $PR --merge` (or `--squash`/`--rebase`) on a repo whose `main` uses a merge queue prints `! The merge strategy for main is set by the merge queue` and ignores the flag — but it still **enqueues** the PR, so that line is a notice, not a failure. Confirm via the queue-entry check (below), not the command's output. Call `gh pr merge $PR` without a strategy flag there and let the queue decide; keep the explicit strategy only for non-queue repos.

## Two facts the loop depends on

**`gh run rerun` reuses the original `GITHUB_SHA`.** For `pull_request` events that is the merge commit computed at first run — a rerun after a base-branch fix still tests against the broken base. Rerun is only for flakes; to pick up a repaired base, rebase the branch and push.

**Review bots converge over multiple rounds.** A `copilot_code_review` rule is not a merge gate: Copilot leaves a `COMMENT` review, which per GitHub's docs does "not count toward required approvals and will not block merging". Nor does every push invalidate the standing review — re-review on push is the rule's `review_on_push` parameter, and when it is unset "Copilot will only review the pull request once". Read the rule's `parameters`, not just its presence: `gh api repos/$R/rules/branches/$BRANCH --jq '.[] | select(.type=="copilot_code_review")'`. Re-request when you want fresh feedback on a new head: `gh api repos/$R/pulls/$PR/requested_reviewers -X POST -f 'reviewers[]=copilot-pull-request-reviewer[bot]'`, then confirm the request registered off the timeline, not off `requested_reviewers` — a reviewer that has *started* drops off that list without having submitted (see `references/pull-request-workflow.md`, "Review on an earlier head + `CLEAN`"). Later rounds may flag UNCHANGED lines adjacent to the diff (latent legacy bugs) — triage each finding on its merits; expect 3–6 rounds on large refactor PRs, with finding severity decreasing per round. Re-arm the watcher after every push.

**A bot review can be a failure notice, not a review — read the body, not the state.** `copilot-pull-request-reviewer` posts its quota and capacity failures as an ordinary `COMMENTED` review whose body is `Copilot was unable to review this pull request because the user who requested the review has reached their quota limit.` Every state-based check reads that as a satisfied gate: `reviews` is non-empty, `reviewThreads` is `0`, inline `comments` is `0`, and `mergeStateStatus` is `CLEAN` — indistinguishable from a clean review that found nothing. Before treating a bot review as landed, read the body:

```bash
gh pr view $PR --repo $R --json reviews \
  --jq '.reviews[] | select(.author.login|test("copilot")) | .body'
```

Treat `unable to review` as **no review** and re-request; if the re-request returns the same notice the quota is still exhausted, and merging means merging unreviewed. Check the repo's recent merged PRs the same way before concluding that a bot review is the local norm — a quota outage can span every PR in a window, so "the last three merged PRs also show COMMENTED" is not evidence they were reviewed.

Once you know the quota is exhausted, mind *when* `--watch` returns: `pr-status.sh --watch` (and any read whose `NEXT` is `request-review`) fires on that review-state event **immediately, even while CI is still running** — the event is independent of check completion, so it returns before the gate can be `CLEAN`. Do not merge on that first return. After deciding to proceed unreviewed, re-arm `--watch` (or watch the checks) until `mergeState=CLEAN`; only `CLEAN` passes the merge gate — `BLOCKED` means checks or threads are outstanding and `UNSTABLE` means a non-required check is still pending (seen 2026-08-12: a docs PR cycled `BLOCKED → UNSTABLE → CLEAN` across three re-arms while the bot stayed quota-dead).

**On a docs/prose PR the loop does not decay — it must be actively terminated.** The bot re-reads the whole changed file each round and keeps surfacing a *new cosmetic* nit (wording, an illustrative example value, a spelling), so pushing a fix just triggers another round almost indefinitely. To converge: once a finding is purely cosmetic and defensible, **reply on the thread and resolve it *without* a new commit** — no push means no re-review means no new nit. Reserve fresh pushes for substantive findings; batch several real fixes into one push rather than one-per-thread.

## A polling watcher must emit on the transition, not on the state

The skeleton above `exit`s when it is done, so it reports each outcome once. A
watcher that instead *streams* events — a `Monitor`-style loop whose stdout lines
become notifications — has no such protection: an emit condition written as a
**state** (`pending == 0 && failures == 0`) is true on every subsequent poll and
republishes the same line every cycle until something stops it. Three identical
"checks complete" notifications for one PR is the usual first symptom, and the
noise buries the event that actually changed.

Latch the last emitted message and print only on change:

```bash
last=""
while true; do
  s=$(gh pr view "$PR" --repo "$R" --json state,statusCheckRollup) || { sleep 60; continue; }
  [ "$(jq -r .state <<<"$s")" != "OPEN" ] && { echo "PR#$PR $(jq -r .state <<<"$s")"; break; }
  fail=$(jq -r '[.statusCheckRollup[]?|select(.conclusion=="FAILURE" or .conclusion=="TIMED_OUT")]|length' <<<"$s")
  pend=$(jq -r '[.statusCheckRollup[]?|select(.status!="COMPLETED")]|length' <<<"$s")
  if   [ "$fail" != 0 ]; then msg="PR#$PR RED"
  elif [ "$pend" = 0 ];  then msg="PR#$PR checks complete, 0 failures"
  else msg=""; fi
  [ -n "$msg" ] && [ "$msg" != "$last" ] && { echo "$msg"; last="$msg"; }
  sleep 60
done
```

Watching several PRs in one loop needs one latch **per PR** (`declare -A seen`),
not one shared variable — otherwise two PRs reaching the same state alternate and
each re-emits.

## Check the producer is switched on before arming the watcher

A watch whose event can never be produced is indistinguishable from one whose
event has not arrived yet: both are silence. Before waiting on a pipeline,
confirm the host will create one at all — a project can have CI switched off
entirely, and then no push, force-push or retarget produces anything to watch.

A `403` confined to one endpoint family while everything else answers `200` with
the same token is *consistent with* that feature being switched off, and equally
with the token lacking the scope for it. Rule the rate limits out by their body
first — `API rate limit exceeded` or `You have exceeded a secondary rate limit`,
per "Watcher cost" below, which is also a 403 and is *not* always global. Then
read the flags, which separate the remaining two:

```bash
# Capture, then parse: `glab … | jq …` exits with jq's status, and jq on empty
# input exits 0, so a || fallback on the pipeline can never fire.
out=$(glab api "projects/:id") \
  || { echo "probe refused — that is the access case, not the feature case"; }
printf '%s' "$out" | jq '{jobs_enabled, builds_access_level}'
# {"jobs_enabled": false, "builds_access_level": "disabled"} -> nothing will run
```

`projects/:id` resolves from the current clone's remote, so run it inside one.

Observed cost: two watchers armed across ~40 minutes for a merge request whose
project had `builds_access_level: disabled`, reported to the user as "no
pipeline yet" when the correct answer was "no pipeline, ever, until someone
re-enables CI". Give a wait a stop condition it can actually reach, and when a
watch stays silent past the expected window, re-check the producer rather than
extending the timeout.

## Auto-merge armed + CLEAN but never enqueued: disable/re-enable to nudge

On a merge-queue repo a PR can sit `CLEAN` with auto-merge **armed** and every required check green, yet never gets a `mergeQueueEntry` — it silently fails to enter the queue, so the watcher just times out. Confirm the symptom, then re-arm to force GitHub to re-evaluate enqueue-readiness:

```bash
gh pr view $PR --repo $R --json mergeStateStatus,autoMergeRequest \
  --jq '{merge:.mergeStateStatus, autoMerge:(.autoMergeRequest!=null)}'   # CLEAN + true
gh api graphql -F o="${R%/*}" -F r="${R#*/}" -F p=$PR -f query='query($o:String!,$r:String!,$p:Int!){repository(owner:$o,name:$r){pullRequest(number:$p){mergeQueueEntry{state}}}}' \
  --jq '.data.repository.pullRequest.mergeQueueEntry // "not queued"'      # "not queued" = stalled

gh pr merge $PR --repo $R --disable-auto     # then re-arm
gh pr merge $PR --repo $R --auto             # → now enters the queue (QUEUED)
```

This is distinct from a PR that entered the queue and was then **dequeued/cancelled** (that one *was* `QUEUED` and dropped — usually a transient queue check failure; re-arm `--auto` there too). Both recover by re-arming; neither is fixed by `--admin`. Renovate/Dependabot PRs arm auto-merge via the deps workflow — a rebase onto current base (they lag) plus this nudge is the non-hand-merge way to complete them.

## Post-merge: confirm merge-triggered jobs by commit SHA, not by run list

After merge, the base branch (`main`) fires its own runs (CI, release, deploy). To confirm those, query the **commit's** checks keyed on the merge SHA — never filter `gh run list` by `headSha`:

```bash
SHA=$(gh pr view $PR --repo $R --json mergeCommit --jq '.mergeCommit?.oid')
gh api repos/$R/commits/$SHA/check-runs --jq '.check_runs[]?|{name,status,conclusion}'
gh api repos/$R/commits/$SHA/status      --jq '{state, total:(.statuses|length)}'   # legacy commit statuses (Sonar/codecov)
```

`gh run list --json … --jq 'select(.headSha=="'$SHA'")'` is unreliable here: the list window is small and time-ordered, so a still-running `main` job scrolls out behind unrelated activity and the filter returns empty — which then feeds a `gh run view ""` (HTTP 404) and tempts a hand-rolled `sleep`-poll loop that just times out. The check-runs/status API is authoritative and SHA-addressed. For PR-head checks, `gh pr checks $PR --watch` already blocks to completion — prefer it over any custom loop.

**Pre-existing red ≠ your regression.** If a post-merge gate (e.g. SonarCloud "Quality Gate failed" on N Security Hotspots) is red, check the *prior* base commit before owning it: `gh api repos/$R/commits/<prev-sha>/check-runs --jq '.check_runs[]?|select(.name=="<gate>")|.conclusion'`. Identical red on the parent + a diff that touched no relevant code = a pre-existing backlog to report, not a regression to fix.

## Delete the branch/worktree only after the merge is CONFIRMED, never on watcher exit

A merge-gate watcher loop can exit for reasons that are **not** "merged": the
PR went `BLOCKED`, an auto-merge was cancelled, or the loop's own condition
tripped on unresolved review threads. Deleting the local branch (or removing the
worktree) the moment the watcher returns — before reading the PR's actual
state — throws away work that is not yet on `main`.

Gate the cleanup on the merge itself, not on the loop returning:

```bash
STATE=$(gh pr view $PR --repo $R --json state --jq .state)
[ "$STATE" = "MERGED" ] || { echo "not merged ($STATE) — keep the branch"; exit 0; }
git -C .bare worktree remove <dir>
git -C .bare branch -D <branch>
```

If the branch was already deleted prematurely, it is usually recoverable from
the remote (`git fetch origin` then re-add the worktree tracking
`origin/<branch>`) — but only while the remote ref still exists (a merged PR's
branch is often auto-deleted). The discipline is cheaper than the recovery:
**confirm `state == MERGED` before any destructive cleanup.**

## A queued PR can silently leave the merge queue

A PR queued via `gh pr merge --auto` on a merge-queue repo can drop back out with no visible event: `isInMergeQueue` flips to `false`, `mergeStateStatus` reads `CLEAN`, and nothing merges. Verify the real queue state via GraphQL (`state` / `merged` / `isInMergeQueue` / `mergeStateStatus`) — a status read that only looks at `mergeStateStatus` reports a dropped PR as merge-ready. Re-arm once (`gh pr merge --disable-auto`, then `--auto`, which forces the queue to re-evaluate); if it drops again, diagnose the queue's required contexts instead of re-arming repeatedly.

### The dequeue reason is on the `gh-readonly-queue` branch, never on the PR

The queue runs the required checks on its own branch, `gh-readonly-queue/<base>/pr-<n>-<sha>`, and a failure there dequeues the entry **silently**: no bot comment, no failed check on the PR, `mergeStateStatus` unchanged. Every PR-scoped query therefore answers "ready and waiting" for a PR that was already thrown out. The runs on that branch are the only record:

```bash
R=owner/repo; PR=123
# --jq is gh's built-in filter and takes no --arg; pipe to real jq when you need one.
gh api "repos/$R/actions/runs?per_page=40" \
  | jq -r --arg p "gh-readonly-queue/main/pr-$PR-" '
      .workflow_runs[] | select(.head_branch | startswith($p))
      | "\(.created_at) \(.name) \(.status)/\(.conclusion)"' | sort -r
```

Then open the failing run's jobs and steps:

```bash
RID=<id from above>
gh api "repos/$R/actions/runs/$RID/jobs" --jq '.jobs[] | select(.conclusion=="failure") | .name'
gh api "repos/$R/actions/jobs/<job-id>/logs"      # the step output, for the actual cause
```

Two consequences for the diagnosis:

- **Time-box the branch filter.** A re-queued PR produces a *second* run set on a branch whose name shares the `pr-<n>-` prefix. A filter matching only the prefix returns the old failed run alongside the new one and reads as a fresh failure. Add `select(.created_at > $since)` with the re-queue time.
- **A dequeue is not evidence of a defect in the PR.** Observed 2026-08-09 (netresearch/t3x-nr-llm#686): five of six workflows green, `Checks` red on one job — `composer audit` exited 100 because `https://packagist.org/api/security-advisories/` answered HTTP 502. The identical workflow had passed on the previous queue branch 30 minutes earlier. Read the step log before concluding anything about the branch; a network-dependent step in a required check turns any upstream outage into a dequeue.

## Watcher cost: GraphQL and REST rate limits are separate budgets

`gh pr view --json statusCheckRollup` is a GraphQL query and an expensive one. Two watchers polling it every 60 s exhausted the **GraphQL** budget (29 of 5000 left) while the REST **core** budget still showed 4614 of 5000 — and once that happened, plain REST calls also began returning `403 API rate limit exceeded`. That combination (one resource drained, the other healthy, both refused) is the **secondary** limit reacting to request density, not the quota. Its 403 body says `API rate limit exceeded` or `You have exceeded a secondary rate limit`, which is what tells it apart from an authorization 403 — read the body, not just the status. Read the resources separately rather than trusting a single number:

```bash
gh api rate_limit --jq '.resources | to_entries[] | "\(.key): \(.value.remaining)/\(.value.limit)"'
```

Three rules follow, and they cost nothing:

- **One watcher per subject.** Two loops on the same PR double the spend and tell you the same thing.
- **Poll REST, not GraphQL, for liveness.** `gh api repos/$R/pulls/$PR` and `gh api repos/$R/commits/$SHA/check-runs` answer state and checks from the cheaper budget.
- **180 s, not 60 s.** A merge queue does not resolve in a minute; the faster interval buys nothing and is what drains the budget.

Recovery is waiting: `gh api rate_limit --jq '.resources.graphql.reset'` is an epoch timestamp — sleep to it in **one** background command rather than retrying into the limit.

### "Has it merged yet?" costs nothing — ask git, not the API

The three rules above make a watcher cheaper. This one makes the commonest watcher free. Once a PR is queued the only question left is whether its head landed on the base, and git answers that with no API budget at all:

```bash
git fetch origin main --quiet
git merge-base --is-ancestor "$HEAD_SHA" origin/main && echo MERGED
```

`$HEAD_SHA` is the PR head you pushed, which you already know. This keeps working while both budgets are exhausted, which is exactly when a watcher is most likely to be running. Reserve `pr-status.sh` for the merge *gate* — checks, threads, reviews, the `NEXT` line — and use git for the merge *fact*.

**Ancestry answers only where the merge preserves the commit.** `--merge` and `--rebase` do; **squash does not** — it writes one new commit with a new hash, so the original head is never an ancestor and the check reads "not merged" forever. In a squash-merge repo, accept one cheap REST call instead: `gh api repos/$R/pulls/$PR --jq .merged`. Know which strategy the repo allows before relying on ancestry — `pr-status.sh` prints it as `merge: methods=[…]`.

**`git log --grep="#<pr>"` is not that test.** It is the tempting one-liner and it produces false positives: `--grep` searches the whole commit *message*, and a dependency bump carries its upstream changelog in the body — including that upstream's issue numbers, from a different repository. Observed 2026-08-13: a watcher on PR #765 reported `MERGED` on its first tick, seven months after the commit it matched. That commit was `chore(deps): bump actions/attest-build-provenance` from January, whose embedded changelog links `actions/attest-build-provenance` issue #765. The PR being watched was in fact `CONFLICTING` and needed a rebuild.

Ancestry is a fact about the graph; `--grep` is a text search over prose that nobody wrote for you to parse.

The same asymmetry as the empty-result rule, inverted: an empty result is first a broken query, and a *positive* result from a text search is first a coincidence.

### When GraphQL is exhausted, REST still opens the PR

`gh pr create` and `gh pr view` are GraphQL; the two budgets drain independently, so `graphql: 0/5000` with `core: 4700/5000` leaves the whole `gh pr *` surface dead while REST is untouched. The REST endpoint takes the same arguments:

```bash
gh api repos/$OWNER/$REPO/pulls -X POST \
  -f title="…" -f head="<branch>" -f base=main -F body=@body.md --jq '.html_url'
```

`gh api repos/$OWNER/$REPO/issues/$PR/comments -X POST -F body=@file` posts a PR comment the same way. Both worked on 2026-08-13 while `gh pr create` returned `GraphQL: API rate limit already exceeded`.

One flag trap while you are there: `gh api --paginate --slurp` is **rejected** together with `--jq` (`the --slurp option is not supported with --jq or --template`). Write the paginated JSON to a file first, then run `jq` over it.

### `gh api` writes its error to stdout — test a field, never emptiness

On a 404 (or any error) `gh api` prints a JSON error object to **stdout** and exits non-zero. A watcher that decides on "did I get output?" reads the error as the answer:

```bash
rel=$(gh api repos/$R/releases/tags/$TAG --jq '.tag_name' 2>/dev/null)
[ -n "$rel" ] && echo "release exists"       # WRONG — fires on the 404 body
case "$rel" in "$TAG") echo "release exists";; esac   # right — tests the value
```

Observed 2026-08-09: a release watcher announced "release published" while the API was still answering 404 and the workflow was mid-run. Match the value you expect, or add `-q` handling that distinguishes exit status from output.
