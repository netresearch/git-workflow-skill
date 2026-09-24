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
      # Resolve first and check it: an empty id, or a rerun that fails, must
      # NOT burn the single retry — otherwise every later iteration skips the
      # rerun that never happened.
      RID=$(gh run list --repo $R --branch $BR --workflow ci.yml --limit 1 \
              --json databaseId --jq '.[0].databaseId') || RID=""
      if [ -n "$RID" ] && gh run rerun "$RID" --repo $R --failed; then
        RERUN_DONE=1; sleep 60; continue
      fi
      echo "HOLD: rerun could not be dispatched (id='${RID:-none}')"; exit 1
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

**Right after a queue merge, the REST view lags.** `gh pr view --json state` can still answer `OPEN` (with `mergeQueueEntry` already `null`) for a short window after the queue merged the PR — which reads exactly like an ejection. The GraphQL state the watcher polls is the settled verdict; when the two disagree, re-query before reporting either. (Observed 2026-08-25: a merged PR was reported "thrown out of the queue" off the stale REST answer and the report had to be corrected minutes later.)

## Two facts the loop depends on

**`gh run rerun` reuses the original `GITHUB_SHA`.** For `pull_request` events that is the merge commit computed at first run — a rerun after a base-branch fix still tests against the broken base. Rerun is only for flakes; to pick up a repaired base, rebase the branch and push.

**Review bots converge over multiple rounds.** A `copilot_code_review` rule is not a merge gate: Copilot leaves a `COMMENT` review, which per GitHub's docs does "not count toward required approvals and will not block merging". Nor does every push invalidate the standing review — re-review on push is the rule's `review_on_push` parameter, and when it is unset "Copilot will only review the pull request once". Read the rule's `parameters`, not just its presence: `gh api repos/$R/rules/branches/$BRANCH --jq '.[] | select(.type=="copilot_code_review")'`. Re-request when you want fresh feedback on a new head: `gh api repos/$R/pulls/$PR/requested_reviewers -X POST -f 'reviewers[]=copilot-pull-request-reviewer[bot]'`, then confirm the request registered off the timeline, not off `requested_reviewers` — a reviewer that has *started* drops off that list without having submitted (see `references/pull-request-workflow.md`, "Review on an earlier head + `CLEAN`"). Later rounds may flag UNCHANGED lines adjacent to the diff (latent legacy bugs) — triage each finding on its merits; expect 3–6 rounds on large refactor PRs, with finding severity decreasing per round. Re-arm the watcher after every push.

**CodeRabbit reports its refusal as a passing commit status.** It writes a legacy commit
status named `CodeRabbit`, and when it declined the description carries the reason while the
state stays green:

```bash
gh api "repos/$R/commits/$SHA/status" --jq '.statuses[] | "\(.context): \(.state) — \(.description)"'
# CodeRabbit: success — Review rate limited
# CodeRabbit: success — Review completed
```

`success — Review rate limited` is a passed check that means *no review happened*, and it
counts toward the "all checks green" line in every summary, including this skill's own.
`pr-status.sh` reports the same refusal from the bot's own summary comment, so the tool and
the status agree — but a human reading the checks tab sees only green. When the question is
whether the head was reviewed, read the description, not the state.

**A bot review can be a failure notice, not a review — read the body, not the state.** `copilot-pull-request-reviewer` posts its quota and capacity failures as an ordinary `COMMENTED` review whose body is `Copilot was unable to review this pull request because the user who requested the review has reached their quota limit.` Every state-based check reads that as a satisfied gate: `reviews` is non-empty, `reviewThreads` is `0`, inline `comments` is `0`, and `mergeStateStatus` is `CLEAN` — indistinguishable from a clean review that found nothing. Before treating a bot review as landed, read the body:

```bash
gh pr view $PR --repo $R --json reviews \
  --jq '.reviews[] | select(.author.login|test("copilot")) | .body'
```

Treat `unable to review` as **no review** and re-request; if the re-request returns the same notice the quota is still exhausted, and merging means merging unreviewed. Check the repo's recent merged PRs the same way before concluding that a bot review is the local norm — a quota outage can span every PR in a window, so "the last three merged PRs also show COMMENTED" is not evidence they were reviewed.

**Your own thread replies are review rows too.** Replying to a review thread creates a `COMMENTED` review under *your* login, on the current head. A wait-for-review watcher that fires on "any review with a `submitted_at`" therefore announces a review after your third reply while the only bot review still sits on the previous head (observed 2026-09-01: three replies, three `COMMENTED` rows by the PR author, "review arrived" reported). Filter on the bot's login **and** the head SHA; the REST rows carry `user.login` and `commit_id`:

```bash
H=$(gh pr view $PR --repo $R --json headRefOid --jq .headRefOid)
gh api "repos/$R/pulls/$PR/reviews" --paginate \
  | jq -r --arg h "$H" '.[] | select(.user.login == "copilot-pull-request-reviewer[bot]" and .commit_id == $h)
                             | "\(.state) \(.submitted_at)"'
```

Once you know the quota is exhausted, mind *when* `--watch` returns: `pr-status.sh --watch` (and any read whose `NEXT` is `request-review`) fires on that review-state event **immediately, even while CI is still running** — the event is independent of check completion, so it returns before the gate can be `CLEAN`. Do not merge on that first return. After deciding to proceed unreviewed, re-arm with `--watch --ignore-action request-review` — it holds through the quota-dead review state and returns once the checks settle (`SETTLED: NEXT is still the ignored action`, exit 0) or something else becomes actionable — and merge only at `mergeState=CLEAN`; only `CLEAN` passes the merge gate — `BLOCKED` means checks or threads are outstanding and `UNSTABLE` means a non-required check is still pending (seen 2026-08-12: a docs PR cycled `BLOCKED → UNSTABLE → CLEAN` across three re-arms while the bot stayed quota-dead).

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

Two more traps sit in the fan-out shape, both measured, and both produce a
*confident* wrong answer rather than an error:

**A per-PR output file keyed by `owner/repo` writes into a directory that does
not exist.** `out="$DIR/gate-$1-$2.txt"` with `$1=netresearch/foo` expands to
`$DIR/gate-netresearch/foo-12.txt`; the redirect fails, every watcher in the
fan-out dies at once, and the only evidence is seven `No such file or directory`
lines buried above the summary. Slugify the whole identity — **not** the
basename: `${1##*/}` drops the owner, so `alice/api` and `bob/api` both land on
`gate-api-12.txt` and one silently overwrites the other, which is the same class
of loss one level down.

**Do not end the fan-out with an `echo` that asserts a state you have not
read.** `for …; do … & done; wait; echo "all gates settled"` prints that line
whether the watchers ran, died on a bad redirect, or were never started —
it is the loop's own claim about itself, not a measurement. Print the
per-PR results, or a count of the result files actually produced:

```bash
PRS=("netresearch/foo 11" "netresearch/bar 12")
dir=$(mktemp -d)
for p in "${PRS[@]}"; do
    set -- $p
    slug=${1//[^A-Za-z0-9._-]/_}              # netresearch/foo -> netresearch_foo
    pr-status.sh -R "$1" "$2" --watch > "$dir/gate-$slug-$2.txt" 2>&1 &
done
wait
ls "$dir"/gate-*.txt | wc -l                  # what exists, not what was intended
```

Both fired in one session: the fan-out over seven pull requests produced no
files and reported that every gate had settled.

### Running `pr-status.sh --watch` under a Monitor

`pr-status.sh --watch` already exits on the first actionable event, so it is the
better producer for a streaming watcher than a hand-rolled loop — but it prints a
`waiting:` line on every poll, and those lines carry advisory prose. A filter that
matches on a bare `error` fires on text such as "delete that file if it was
recorded in error" and turns every poll into a notification. Drop the heartbeat
first, then keep only the lines you act on:

```bash
pr-status.sh -R OWNER/REPO "$PR" --watch 2>&1 \
  | grep --line-buffered -vE '^waiting' \
  | grep --line-buffered -E '^(ACTIONABLE|TIMEOUT|SETTLED|NEXT)|^\s*(failing|checks)|pr-status:'
```

`ACTIONABLE`, `TIMEOUT`, `SETTLED` (the return of `--ignore-action` once checks
settle) and `pr-status:` (the tool's own failures, including the
`pr-status: UNREADABLE —` line for a gate that cannot be queried at all, with
the cause on stderr) cover every terminal state, so silence still means
"waiting", never "crashed unseen". Anything added to the producer has to carry
one of these prefixes or be added here — a state the filter drops is a state
nobody sees.

Prefer the Monitor tool over a backgrounded shell for these long waits. Two
backgrounded `pr-status.sh --watch` processes in one session were stopped by the
harness with "the system is running low on memory" while CI queued for hours; the
same watch under Monitor ran to its event. A watch that was killed reports
nothing, so after such a stop, read the gate once directly
(`pr-status.sh -R OWNER/REPO "$PR"`) before arming the next one.

### Key the verdict on `--json .next.action`, never on the `NEXT:` prose

The rule above is about noise; this one is about a wrong verdict, and it is the
same mechanism one step worse. A hand-rolled loop that polls `pr-status.sh` and
decides by matching the human `NEXT:` line matches the **explanation**, not the
state: the `why` text for `request-review` reads *"no review on the current head
… do not merge unreviewed"*, so a `case "$line" in *merge*)` arm fires on a gate
that is shut and announces the opposite of the truth.

```bash
# ❌ matches the reason, not the state — "do not merge unreviewed" contains "merge"
line=$(pr-status.sh -R "$R" "$PR" | grep '^NEXT:')
case "$line" in *merge*) echo "GATE OPEN";; esac

# ✅ the state is a field
act=$(pr-status.sh -R "$R" "$PR" --json | jq -r '.next.action')
[ "$act" = "merge" ] && echo "GATE OPEN"
```

The human line is for a human; `--json` is the machine contract, and
`.next.action` is one token from a fixed vocabulary. Do not copy that vocabulary
into your loop — it grows with the script (18 values at 1.32.4, from `merge` and
`ready` through `await-capacity` and `rules-unavailable`). Match the handful you
act on by exact string, and treat every other value as "keep waiting": an
unrecognised action then delays you, where a substring match on prose reports
success.

### A watcher is armed on a head; stop it when the head moves

A loop polling a pull request keeps polling after a force-push, and its next
notification describes a state that no longer exists — while the watcher you
armed on the *new* head reports beside it. Two watchers on one PR disagreeing is
indistinguishable from a flapping gate. Stop the old one when you rewrite the
branch (`TaskStop`, or whatever ends the producer), and name the head in the
watcher's description so a stale event is recognisable as stale.

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

### Armed in the same breath as the push: "no checks reported", exit 0

The producer can be switched on and the runs still not exist yet. `gh pr checks
<n> --watch` started seconds after a push prints

```
no checks reported on the 'task/whatever' branch
```

and **exits 0** — GitHub had not registered the workflow runs for the new head
when the first poll landed. Exit 0 plus no failures reads exactly like "all
green", which is the dangerous part: nothing in that output says the watcher
never watched anything.

Two consequences for the loop:

- Read the watcher's output, not only its exit code. A run that ends on the
  "no checks reported" line watched nothing and has to be re-armed.
- Give the runs a moment to appear, or arm the watcher on a read that has
  already seen at least one check. A plain `gh pr checks <n>` right after the
  push shows whether anything is `pending` yet; arm `--watch` once it does.

Seen 2026-09-18 on a rebase-and-force-push: the watcher returned immediately,
`gh pr checks` a moment later listed seven checks all `pending`, and the
re-armed watcher then reported them green.

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

### A check run is named after the JOB, not the workflow

Looking for a workflow by its own name in `commits/$SHA/check-runs` finds nothing, and the natural conclusion — "that run does not exist for this commit" — is wrong. The entry is there under the **job** name.

Measured on `netresearch/typo3-demo`: workflow run 32536686040 is `Deploy (Update)` (`event=workflow_run`, `check_suite_id=88200944968`); its check run 96938832284 is named `deploy`. Same check suite, and the check run's `html_url` points back at `/actions/runs/32536686040/job/96938832284`. Reproduced 4/4 there and 2/2 on `netresearch/ofelia`, where `Verify Release` appears as `Verify / Verify Release`.

So match on the check suite or on the job names you expect, not on the workflow name — and never infer absence from a name miss.

### When you want run-level state, filter server-side with `head_sha=`

The workflow run's own `status`/`conclusion` (as opposed to its jobs') lives on the runs endpoint. Do **not** reach back for a windowed list and filter it yourself — `actions/runs` takes the SHA as a query parameter and filters on the server:

```bash
[ -n "$SHA" ] || { echo "no SHA — refusing to watch"; exit 1; }
gh api "repos/$R/actions/runs?head_sha=$SHA&per_page=50" \
  --jq '.workflow_runs[] | "\(.name)=\(.status)/\(.conclusion // "-")"'
```

The guard on the first line is not decoration. An **empty** `$SHA` drops the filter silently and the API answers with the unfiltered list — 4506 runs on one repository measured this way, against 0 for a syntactically valid unknown SHA and 0 for outright garbage. A watcher whose SHA lookup failed then extracts some unrelated run's state and reports it as the watched commit's; the extraction is not empty, so the value guard below cannot catch it.

A **shortened** SHA fails the other way. `head_sha=` resolves only the full 40-character SHA, so an abbreviated one (`5ddd65df8`) is just another unknown value: every tick returns an empty list, and a loop that reads "no runs" as "still running" spins through its whole budget in silence. Take the SHA from `git rev-parse` or `headRefOid`, never from a short form typed for readability.

`repos/$R/actions/runs?per_page=20` piped into a client-side `select(.head_sha==$s)` has the same window defect as `gh run list`, with one difference that makes it worse in a loop: **it works on the first tick.** The commit is recent, so it sits inside the window; twenty minutes later unrelated runs have pushed it out and every subsequent tick sees nothing. A watcher built that way reports progress, then goes quiet, and quiet is indistinguishable from "still running" — it will sit out its full budget without ever emitting. (Observed 2026-08-21; the first tick listed five runs, later ticks listed none.)

### The emptiness guard must test the extracted value, not the response

The natural guard is on the API call:

```bash
json="$(gh api "…" 2>/dev/null || echo '')"
if [ -z "$json" ]; then sleep 45; continue; fi     # never fires
```

That checks the wrong thing. When the window scrolls past the commit the response is a perfectly valid `{"workflow_runs": []}` — non-empty, well-formed, and about a different set of runs. Guard on the value you actually extracted, and make a persistent extraction failure say so, because a watcher that has gone blind must not look like a watcher that is waiting:

```bash
state="$(printf '%s' "$json" | jq -r '…')"
if [ -z "$state" ]; then
  errors=$((errors + 1))
  [ "$errors" = "5" ] && echo "query has returned nothing for 5 rounds — this watch is blind"
  sleep 45; continue
fi
errors=0
```

A fallback can corrupt the **value** a correct guard then accepts. `curl -s -w '%{http_code}'` already prints `000` on a connection failure, so `code=$(curl -s -o /dev/null -w '%{http_code}' "$URL" || echo 000)` yields `000000` on that path; a guard written as the negation of failure (`[ "$code" != "000" ]`) passes it, and the watcher reports a terminal state on its first tick (observed 2026-09-07: `TERMINAL: 000000`, a false "the site is up" before its certificate existed). A tool that already emits a sentinel on failure needs no `|| echo` fallback, and the failure case must be matched **positively and first**. Bound the request as well: without `--max-time` a stalled connection never reaches the check (a timed-out request also prints `000`):

```bash
code=$(curl -s --connect-timeout 10 --max-time 30 -o /dev/null -w '%{http_code}' "$URL")
case "$code" in
  000|"") echo "unreadable: '$code'"; sleep 30; continue ;;
esac
```

### "Every run has finished" is true before any run exists — and a second query cannot repair it

A tag push or a merge does not create the workflow runs immediately; for a second or two `actions/runs?head_sha=…` answers `{"workflow_runs": []}` for a SHA that will carry several. A loop whose condition is "no run has a status other than `completed`" is therefore **vacuously true on its first tick**, exits at once, and reports a settled state that never happened. The guard in the previous section does not catch this one: the extraction succeeds, it just extracts a count of zero from an honest empty list.

The reflex repair is a second condition — "and the list is not empty". Put it in a **second API call** and the two conditions stop describing the same moment:

```bash
# WRONG — two calls, two different instants
until [ "$(gh api "…" --jq '[.workflow_runs[]|select(.status!="completed")]|length')" = 0 ] \
   && [ "$(gh api "…" --jq '.workflow_runs|length')" != 0 ]; do sleep 60; done
```

The runs appear *between* the calls: the first sees none unfinished because it sees none at all, the second sees them and reports non-empty, and the loop exits on its first pass. Observed 2026-09-22 on `netresearch/ldap-manager` v1.7.0 — the loop returned instantly and printed `Release: null` and `CI: null`, which are a `queued` and an `in_progress` run.

Both facts have to come out of **one** response:

```bash
gh api "repos/$R/actions/runs?head_sha=$SHA&per_page=100" \
  --jq '[.workflow_runs[]] as $r | ($r|length) > 0 and ([$r[]|select(.status!="completed")]|length) == 0'
```

Even that only answers for the runs that exist *now*, so a watcher waiting on two workflows can still settle while the second has not been created. Where you know which workflow matters, resolve its run once and let `gh` block on it — the id fixes the subject, and the exit code carries the conclusion:

```bash
RID=$(gh api "repos/$R/actions/runs?head_sha=$SHA&per_page=100" \
        --jq '[.workflow_runs[]|select(.name=="Release")][0].id')
[ -n "$RID" ] && [ "$RID" != "null" ] || { echo "no Release run for $SHA yet"; exit 1; }
gh run watch "$RID" --repo "$R" --exit-status
```

### A file read right after a merge can still return the pre-merge content

`contents/<path>?ref=<branch>` has been observed answering with pre-merge content immediately after a merge. A post-merge verification that reads the branch ref can therefore report the merged change as **absent** — an invented regression, produced by measuring too early rather than by anything being wrong. The mechanism is not established here (no attempt was made to reproduce it against a controlled merge); what is established is that the branch ref answered stale and the merge commit answered correctly. Address the merge commit, the same way the rest of this section does:

```bash
MC=$(gh api "repos/$R/pulls/$PR" --jq '.merge_commit_sha')
gh api "repos/$R/contents/<path>?ref=$MC" --jq '.content' | base64 -d | grep -q '<marker>'
```

Observed 2026-08-21: a watcher fired "the trigger is NOT on main" the moment the PR merged; a direct read at the merge SHA a minute later showed it present, at the expected lines.

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

A PR queued via `gh pr merge --auto` on a merge-queue repo can drop back out with no visible event: `isInMergeQueue` flips to `false`, `mergeStateStatus` reads `CLEAN`, and nothing merges. Verify the real queue state via GraphQL (`state` / `merged` / `isInMergeQueue` / `mergeStateStatus`) — a status read that only looks at `mergeStateStatus` reports a dropped PR as merge-ready. Confirm the drop on the PR timeline first — the latest queue event is `removed_from_merge_queue`, with no `added_to_merge_queue` or `merged` after it (query in `pull-request-workflow.md`, "Verify a 'dropped' queue entry via the issue timeline before re-arming") — because re-queuing a PR whose queue run is still in flight cancels that run (see below). Then re-arm once (`gh pr merge --disable-auto`, then `--auto`, which forces the queue to re-evaluate); if it drops again, diagnose the queue's required contexts instead of re-arming repeatedly.

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

Three consequences for the diagnosis:

- **Time-box the branch filter.** A re-queued PR produces a *second* run set on a branch whose name shares the `pr-<n>-` prefix. A filter matching only the prefix returns the old failed run alongside the new one and reads as a fresh failure. Bind the re-queue time in the `jq` call — `--arg since "$REQUEUE_TIME"`, ISO 8601 such as `2026-09-22T22:20:00Z`, the format `created_at` uses, so the string comparison orders correctly — and add `select(.created_at > $since)` to the filter.
- **A dequeue is not evidence of a defect in the PR.** Observed 2026-08-09 (netresearch/t3x-nr-llm#686): five of six workflows green, `Checks` red on one job — `composer audit` exited 100 because `https://packagist.org/api/security-advisories/` answered HTTP 502. The identical workflow had passed on the previous queue branch 30 minutes earlier. Read the step log before concluding anything about the branch; a network-dependent step in a required check turns any upstream outage into a dequeue.
- **A red job can be a race with the queue's own cleanup.** Observed 2026-09-22 (netresearch/t3x-nr-llm#957): the required `All security checks` job failed because its SARIF upload targeted the queue branch after the queue had already deleted it — `ref 'refs/heads/gh-readonly-queue/main/pr-<n>-<sha>' not found` — while every Opengrep finding was suppressed and 0 were uploaded. That is not a finding. Re-queue.

### A queue entry also drops when its jobs never start

The queue has its own timeout, and it is not on the PR or in the workflow: it is the ruleset's `merge_queue` parameter `check_response_timeout_minutes`.

```bash
gh api "repos/$R/rulesets/<id>" --jq '.rules[] | select(.type=="merge_queue") | .parameters'
# {"check_response_timeout_minutes":60, …}
```

When the queue run's jobs are still `queued` — not `in_progress` — once that limit passes, the entry is dropped with **no failed check** anywhere. That is runner starvation, not a defect in the PR. Tell it apart on the queue run itself:

```bash
gh api "repos/$R/actions/runs/$RID/jobs" --jq '.jobs[] | "\(.name) \(.status)"'   # every job `queued`
gh api "repos/$R/actions/runs?status=in_progress" --jq '.total_count'              # 0
```

Observed 2026-09-22 on netresearch/t3x-nr-llm#957: from 22:20Z the CI run's 39 jobs stayed `queued` for over an hour, while short workflows on the same queue branch finished and other repositories in the organisation also had only queued runs. githubstatus.com reported Actions operational, and billing was not the cause.

Re-enqueueing after such a drop is not reliable. On the same PR GitHub re-enqueued it once on its own (auto-merge was still armed) and once did not — although that run later finished green, after the timeout had already dropped the entry. Once runners move again, re-queue by hand: `gh pr merge <n>`, or `pr-merge.sh`.

### Re-queuing cancels the run already in flight

Re-adding a PR to the merge queue **cancels the queue run in progress**, so a retry loop prevents the very merge it is meant to cause. Observed 2026-08-06 on netresearch/t3x-nr-llm#616: a loop tried to re-queue the PR about every two minutes, 128 attempts, and the timeline records six `added_to_merge_queue` events. The first queue run completed the required E2E workflow green; in the next two the E2E run shows `cancelled` — once two seconds before the matching `removed_from_merge_queue` — and the PR merged on the fourth queue run, which was left to finish.

The loop's trigger was a false ejection: the GraphQL `mergeQueue.entries` list reads **transiently empty** for an entry that is still queued. Requiring two consecutive empty reads did not fix it; the signal is wrong, not noisy. Let one queue attempt run to completion, and re-queue only when the latest queue event on the timeline is `removed_from_merge_queue`, with no `added_to_merge_queue` or `merged` after it, never because the entry is missing from the queue list. When a required check on the queue branch never reports, diff required against reported contexts, and check whether something you are doing is cancelling the run.

### Watching a queued PR: ask git

What the PR-scoped tools do once the PR is queued:

- `pr-status.sh --watch` keeps polling. `wait` is not an actionable NEXT, so every interval (default 20 s) it prints `waiting: already in the merge queue at position …` — a heartbeat, not a hang. It returns when the entry leaves the queue: `ACTIONABLE: none` with `PR is MERGED` after the merge, the next actionable step (for example `merge`) after a silent drop, or `TIMEOUT` after `--max-wait` (default 3600 s). Each poll is a GraphQL read, so a long queue wait spends GraphQL budget (see [Watcher cost](#watcher-cost-graphql-and-rest-rate-limits-are-separate-budgets)).
- `gh pr view --json isInMergeQueue` fails with `Unknown JSON field`. The field exists only in GraphQL, as `repository.pullRequest.isInMergeQueue`.

The git ancestry check in ["Has it merged yet?" costs nothing — ask git, not the API](#has-it-merged-yet-costs-nothing--ask-git-not-the-api) answers "has it merged" without any API budget.

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

### What still works while GraphQL is drained

`pr-status.sh` is GraphQL end to end, so it exits `GraphQL query failed` and the
whole finish flow appears blocked. Most of it is not. `rate_limit` can even
report `5000/5000` for both resources while GraphQL refuses — the counter is not
where a secondary limit shows up, so probe it directly instead of believing the
number, and classify the failure rather than assuming the worst: a 401, a DNS
error and a throttle all make `gh api` exit non-zero, and only one of them is
worth waiting an hour for.

```bash
err=$(gh api graphql -f query='{viewer{login}}' 2>&1 >/dev/null) && echo up \
  || case "$err" in
       *RATE_LIMIT*|*"rate limit"*|*"secondary rate"*) echo throttled ;;
       *) echo "graphql down, not throttled: $err" ;;
     esac
```

Answerable from REST, which is usually still healthy:

| Question | REST call |
|---|---|
| head SHA, base, draft state | `gh api repos/$R/pulls/$PR` |
| check runs on the head | `gh api "repos/$R/commits/$SHA/check-runs?per_page=100" --paginate` |
| legacy commit statuses | `gh api "repos/$R/commits/$SHA/status?per_page=100" --paginate` |
| reviews submitted | `gh api "repos/$R/pulls/$PR/reviews?per_page=100" --paginate` |
| reviewers still requested | `gh api repos/$R/pulls/$PR/requested_reviewers` |
| effective rulesets on the base | `gh api "repos/$R/rules/branches/$ENC_BASE?per_page=100" --paginate` |
| merge (direct only) | `gh api repos/$R/pulls/$PR/merge -X PUT -f sha="$SHA" -f merge_method=merge` |

Four details the table hides.

**Checks are two endpoints, not one.** `check-runs` does not carry legacy commit
statuses, so a repository whose required contexts are classic statuses looks
green with none of them read. Query both.

**Every one of these paginates.** Default page size is 30 — `reviews`,
`check-runs` and the rulesets array all truncate silently, which is the same
trap this file warns about elsewhere.

**The rulesets path takes the branch as a path segment**, so a base like
`release/2.1` must be URI-encoded first (`pr-status.sh` encodes it for exactly
this reason):

```bash
ENC_BASE=$(printf %s "$BASE" | jq -sRr @uri)
```

**Pin the head when merging through REST.** Without `-f sha="$SHA"` the endpoint
merges whatever the head is at the moment it runs, so a push that lands between
the gate check and the call is merged unreviewed. This row is also
direct-merge-only: the endpoint has no merge-queue mode, so a queue repository
needs its own flow rather than this fallback.

The one thing with **no** REST equivalent is converting a draft to ready
(`markPullRequestReadyForReview`); review-thread resolution
(`resolveReviewThread`) is GraphQL-only too. Requesting a review is not on that
list — `POST /pulls/$PR/requested_reviewers` works on a draft, and Copilot does
review drafts, so a bot-review ruleset is not automatically a hard stop while
the budget is out. Confirm the request off the **timeline**, not off
`requested_reviewers`: the response body does not echo a bot reviewer, and a
reviewer that has started drops off that list without having submitted.

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

### Pass `--workflow` a file name — a display name resolves only while it is unique

`--workflow` accepts a name, an id or a file name, so `gh run list --workflow CI`
is valid — right up to the moment the selector matches more than one workflow.
Then `gh` refuses with

```
could not resolve to a unique workflow; found: codeql.yml codeql
```

and prints it on **stderr with a zero-length stdout**. Inside an `until` loop
that compares a captured count, the empty string is not the terminating value,
so the loop never exits — it spins on the error for as long as it is left
running, and from the outside that is indistinguishable from "the run has not
finished yet". Observed on `netresearch/.github`, where a watcher polled a
resolution error for hours while the run it was waiting for had long since
completed.

Prefer the file name — `--workflow codeql.yml`, `--workflow ci.yml` — which is
unique by construction and cannot start colliding later when somebody adds a
workflow. And when a loop's condition is built from a command that can fail,
make the failure terminate it rather than feed it: check the exit status, or
`|| break`.
