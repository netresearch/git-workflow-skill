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
