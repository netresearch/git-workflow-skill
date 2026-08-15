# CI/CD Integration

## Watching CI from the CLI

When waiting on PR CI from the command line (or an agent), use the native
watchers — do not hand-roll a poll loop:

```bash
# Wait for all PR checks; exits non-zero if any required check fails.
gh pr checks <pr> --repo <owner/repo> --watch --fail-fast

# Watch a single workflow run by ID (when you have the run, not the PR).
gh run watch <run-id> --repo <owner/repo> --exit-status
```

Gate on the **exit code**, not on parsed output. `gh pr checks` and
`gh run watch` already handle pending-state representation, the appearance of
newly-triggered runs, and refresh.

### `$(gh api … || echo "")` captures the ERROR BODY as data

On an HTTP error (404, 403 rate limit, 5xx) `gh api` prints the JSON error
body to **stdout** and does not apply `--jq` to it — so the classic fallback
capture poisons the variable instead of emptying it:

```bash
# Wrong: on a 404, $rel holds '{"message":"Not Found",…}' — non-empty,
# and every [[ -n "$rel" ]] downstream believes it is real data
rel=$(gh api "repos/$R/releases/latest" --jq .tag_name 2>/dev/null || echo "")

# Right: output reaches the variable only when the call SUCCEEDED
if out=$(gh api "repos/$R/releases/latest" 2>/dev/null); then
  rel=$(jq -r '.tag_name // empty' <<<"$out")
else
  rel=""
fi
```

Verified with gh 2.97 (2026-08-13): a fleet survey using the wrong form
classified never-released repos from their own error bodies. The same trap
applies to `glab api` — gate on the exit code, never on non-empty stdout.

### `gh run watch` takes the RUN id — a check-run's `details_url` ends in the JOB id

Reaching for `gh run watch` from a check-run means extracting an id from its
`details_url`, which looks like `…/actions/runs/<RUN>/job/<JOB>`. Taking the
trailing number hands over the **job** id, and that failure is silent in the
worst way: the API answers `404`, `gh run watch` prints `failed to get run` and
**still exits 0**. Under `--exit-status`, in a background waiter, that reads as
"the run finished, and it passed" — the waiter never waited at all.

```bash
# Wrong: trailing number is the job id
rid=$(gh api "repos/$R/check-runs/$ID" --jq '.details_url' | grep -oE '[0-9]+$')

# Right: name the segment
rid=$(gh api "repos/$R/check-runs/$ID" --jq '.details_url' \
      | grep -oE 'runs/[0-9]+' | cut -d/ -f2)

# Or take the run id straight from the commit's check-runs
gh api "repos/$R/commits/$SHA/check-runs?per_page=100" --paginate \
  --jq '.check_runs[] | select(.status != "completed")
        | "\(.name)\trun=\(.details_url | capture("runs/(?<r>[0-9]+)").r)"'
```

Because the exit code cannot distinguish "watched and passed" from "never
found the run", assert the run exists before watching it, or re-read the
check's state afterwards rather than trusting the watcher's return.

### Ask which step failed before reading any log

The jobs API names it in one call, and the name is usually enough to reproduce
the failure locally:

```bash
gh api repos/$R/actions/jobs/$JOB \
  --jq '.steps[] | select(.conclusion=="failure") | .name'
```

Reaching for the log first costs rounds that return nothing, because the
failing step's output is often not in what you get back (see the next section)
and every keyword filter then matches the surrounding noise instead —
provisioning, `tar` invocations, a `harden-runner` audit stream, and in one case
a validator's own green `Errors: 0` summary. Four such calls produced no
information about a failure whose step was called `Python lint`; the API call
above answered on the first try.

### A green pre-commit run is not a green CI lint step

Two distinct reasons, and the second is the one that is easy to miss.

**The run was not green.** `pre-commit` reports a reformatting hook as a
failure, and the report is easy to discard: `pre-commit run --files … | grep -vE
'Skipped|Passed' | tail -4` printed `- files were modified by this hook` and `2
files reformatted`, which was read as success. Never filter or truncate
`pre-commit` output — `files were modified by this hook` is a failed run, and
the hook names are how you tell which.

**The versions differ.** Even a genuinely green run proves only what the
*pinned* version thinks. `.pre-commit-config.yaml` pins
`astral-sh/ruff-pre-commit` by `rev`, while the CI step pins its own
(`uvx ruff@0.16.0 check`). Measured on the same file: ruff 0.15.14, the
pre-commit pin, reported `All checks passed!` while ruff 0.16.0, the CI pin,
failed it on `SIM905`. The rule was newer than the hook. So keep the two pins in
parity and let dependency updates move them together; when they disagree, the
CI's version is the one that decides, and running the linter merely "by name" is
not enough.

### The step output of a failed job comes from the RUN's log archive

`gh api repos/$R/actions/jobs/$JOB/logs` and `gh run view --job $JOB --log`
routinely hand back only the runner's own preamble — image provisioning,
hardening-agent chatter, `Cleaning up orphan processes` — with the failing
step's output absent entirely. One of them can also return an empty body and
exit 0. Filtering that noise then produces nothing and reads as "the log says
nothing about why it failed", which sends you diagnosing the wrong layer.

Download the **run's** archive instead. It contains one text file per job, with
the real step output:

```bash
gh api "repos/$R/actions/runs/$RUN/logs" > /tmp/logs.zip
unzip -q -o /tmp/logs.zip -d /tmp/logs
grep -rn '##\[error\]' /tmp/logs | grep -viE 'armour|agentservice|pam_unix'
```

On 2026-08-12 this was the difference between three unexplained merge-queue
ejections and one line — `[ERROR] Undefined constant …PHPUnitSetList::PHPUNIT_110`
— that named the cause outright. The job-level calls had been tried first and
showed nothing but setup.

Note the archive is per *run*, so for a queue ejection you need the
`gh-readonly-queue/*` run, not the pull request's own:

```bash
gh run list --repo "$R" --limit 20 --json headBranch,databaseId,conclusion \
  --jq '.[] | select(.headBranch | startswith("gh-readonly-queue"))'
```

Hand-rolled `gh pr checks | jq` poll loops re-derive those semantics from
undocumented field shapes (a running check's `conclusion` may be `""`, `null`,
or absent) and are a recurring source of bugs. The sharpest one: a poll run
**immediately after a push, reopen, or re-trigger** reads "0 pending" *before*
the freshly-queued run has registered, so the loop reports a false "all green"
and you act prematurely. A bare `[ "$pending" -eq 0 ] && break` snapshot is true
both before runs start and after they finish — it cannot tell the two apart.

If you must hand-roll (e.g. watching something with no native watcher), gate on
a **named required check reaching a terminal `pass`/`fail` state**, never on a
zero-pending count, and confirm the run belongs to the current head SHA first.

`pr-status.sh --json` answers this in one field: **`checks_settled`** is true
only when nothing is pending *and* every required context has reported at
least once. Gate on that rather than re-deriving it — and note the `NEXT:` line
does not carry it, because the review branches of the ladder outrank every CI
branch. On a repo with the `copilot_code_review` ruleset, `NEXT:` says
`request-review` from the second a commit lands and keeps saying it; the CI
state now rides along in that answer's `why`, but a script should read the
field.

## Before you add or edit a workflow file: read the repo's Actions policy

A workflow that violates the repository's Actions policy fails at **`Set up job`**
— before a single step runs — so the log shows no step output and the failure
looks unrelated to the change. One API call answers it:

```bash
gh api repos/$R/actions/permissions --jq '{allowed_actions, sha_pinning_required}'
gh api orgs/${R%/*}/actions/permissions --jq '{allowed_actions, sha_pinning_required}'
```

Check the **org** as well: it can require pinning that the repo's own setting
does not mention. With `sha_pinning_required: true`, every `uses:` needs a full
commit SHA — a tag ref (`actions/checkout@v6`) is refused:

```bash
gh api repos/actions/checkout/git/ref/tags/v6 --jq '.object.sha'   # then: @<sha> # v6
```

The same policy is what the workflow-security linters enforce, so the cost of
skipping this check is not one red check but several: adding a job with two
unpinned `uses:` turned **six** checks red at once — `Set up job`, zizmor,
Opengrep, CodeQL, SonarCloud and the aggregate security gate — all reporting the
same two lines. Prefer dropping an action over pinning it where the runner
already provides the tool (`setup-php` for a script that needs no extensions,
`setup-node` for a plain `npx`).

## A CI linter's finding is not refuted by a differently-scoped local run

Running the same linter locally and getting the same *number* of findings is not
evidence that they are the same findings. Two axes differ routinely:

- **Scope.** A CI integration usually reports only what the pull request
  *changed*; a local invocation lints the whole file or the whole tree.
- **Policy source.** The CI action may load a config, a baseline, or an
  organisation policy the local binary does not see — and vice versa.

Observed: a local `zizmor` run flagged three unpinned `uses:` and the same three
appeared on the base branch, which read as "pre-existing, not mine". CI's zizmor
reports changed code only, and its three findings were the author's own two new
lines plus a note on them. Same count, disjoint findings, and the wrong
conclusion was stated publicly before the alerts were read.

Compare **locations**, not counters:

```bash
gh api "repos/$R/code-scanning/alerts?tool_name=<tool>&pr=$PR&state=open" \
  --jq '.[] | "\(.rule.id)\t\(.most_recent_instance.location.path):\(.most_recent_instance.location.start_line)"'
```

If the paths and lines are yours, the finding is yours — whatever the local run
says.

## Git Mirror Repositories

Use `git clone --mirror` + `git push --mirror` to keep a target repository in sync with an
upstream source — for example, mirroring a public TYPO3 repository into a private GitLab
instance or creating read-only forks for controlled distribution.

```bash
git clone --mirror "$SOURCE_URL" repo.git
cd repo.git
git push --mirror "$TARGET_URL"
```

### Default Branch Requirement

`git push --mirror` pushes **all** refs from the source and **deletes** any ref at the target
that no longer exists in the source. GitLab and GitHub will refuse to delete their repository's
default branch, causing the push to fail with an error like:

```
remote: GitLab: You can only delete protected branches using the web interface.
error: failed to push some refs to 'git@gitlab.example.com:org/repo.git'
```

**Root cause**: the target was initialised with a default branch (e.g. `main`) that does not
exist in the upstream (e.g. source uses `12.4`). Every mirror run tries to delete `main` and
GitLab refuses.

**Fix — preferred**: create the target as an **empty project** (no README, no initial commit).
The default branch is then set automatically when the first `git push --mirror` runs.

**Fix — existing repo**: change the default branch in Settings before mirroring. On GitLab:
*Settings → Repository → Default branch*. On GitHub: *Settings → Branches → Default branch*.

### Notes-Ref Gotcha

`git push --mirror` deletes any ref at the target that does not exist in the upstream. If you
store cache data (e.g. split commit maps) in `refs/notes/*` on the mirror target, those refs
will be wiped on every sync run because they are absent from the upstream.

Do not rely on `refs/notes/*` for persistent caching in mirror repositories. Store such state
in a separate repository, a file in object storage, or a CI/CD cache artifact.

### Example CI Job (GitLab)

```yaml
mirror-sync:
  image: alpine/git:2.43.0
  script:
    - git clone --mirror "$SOURCE_URL" repo.git
    - cd repo.git
    - git push --mirror "$TARGET_URL"
  only:
    - schedules
```
