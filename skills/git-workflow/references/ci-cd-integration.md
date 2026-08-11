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
