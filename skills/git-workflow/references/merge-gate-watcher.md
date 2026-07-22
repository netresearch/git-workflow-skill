# Merge-Gate Watcher

Canonical polling loop to drive a PR to merge once review threads are handled. Hand-rolling this per PR invites classification bugs (a soft check counted as hard ⇒ false HOLD; a missed one ⇒ premature merge).

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

Merge-despite is defensible only when the sole failing condition is a touched-line re-attribution metric (`new_duplicated_lines_density`, patch coverage on refactor-moved lines), open PR issues are 0, and the PR body documents the rationale. Real findings: fix them.

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

## Two facts the loop depends on

**`gh run rerun` reuses the original `GITHUB_SHA`.** For `pull_request` events that is the merge commit computed at first run — a rerun after a base-branch fix still tests against the broken base. Rerun is only for flakes; to pick up a repaired base, rebase the branch and push.

**Review bots converge over multiple rounds.** Every push invalidates the review (ruleset `copilot_code_review` needs a fresh review on the latest head), so re-request after each push: `gh api repos/$R/pulls/$PR/requested_reviewers -X POST -f 'reviewers[]=copilot-pull-request-reviewer[bot]'`. Later rounds may flag UNCHANGED lines adjacent to the diff (latent legacy bugs) — triage each finding on its merits; expect 3–6 rounds on large refactor PRs, with finding severity decreasing per round. Re-arm the watcher after every push.

**A bot review can be a failure notice, not a review — read the body, not the state.** `copilot-pull-request-reviewer` posts its quota and capacity failures as an ordinary `COMMENTED` review whose body is `Copilot was unable to review this pull request because the user who requested the review has reached their quota limit.` Every state-based check reads that as a satisfied gate: `reviews` is non-empty, `reviewThreads` is `0`, inline `comments` is `0`, and `mergeStateStatus` is `CLEAN` — indistinguishable from a clean review that found nothing. Before treating a bot review as landed, read the body:

```bash
gh pr view $PR --repo $R --json reviews \
  --jq '.reviews[] | select(.author.login|test("copilot")) | .body'
```

Treat `unable to review` as **no review** and re-request; if the re-request returns the same notice the quota is still exhausted, and merging means merging unreviewed. Check the repo's recent merged PRs the same way before concluding that a bot review is the local norm — a quota outage can span every PR in a window, so "the last three merged PRs also show COMMENTED" is not evidence they were reviewed.

**On a docs/prose PR the loop does not decay — it must be actively terminated.** The bot re-reads the whole changed file each round and keeps surfacing a *new cosmetic* nit (wording, an illustrative example value, a spelling), so pushing a fix just triggers another round almost indefinitely. To converge: once a finding is purely cosmetic and defensible, **reply on the thread and resolve it *without* a new commit** — no push means no re-review means no new nit. Reserve fresh pushes for substantive findings; batch several real fixes into one push rather than one-per-thread.

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
