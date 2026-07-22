# Git Hooks Setup

## Why Hooks Matter

Git hooks catch issues before they reach CI — faster feedback, fewer wasted CI runs.
For autonomous agents, hooks are essential: they enforce commit message format,
prevent secrets, and ensure code quality without requiring the agent to "remember" rules.

## Hook Frameworks

| Framework | Language | Config File | Install |
|-----------|----------|-------------|---------|
| **lefthook** | Go binary | `lefthook.yml` | `go install github.com/evilmartians/lefthook@latest && lefthook install` |
| **captainhook** | PHP | `captainhook.json` | `composer install` (auto via plugin) |
| **husky** | Node.js | `.husky/` | `npm install` (auto via prepare) |
| **pre-commit** | Python | `.pre-commit-config.yaml` | `pip install pre-commit && pre-commit install` |

## Detection — One Command

```bash
ls lefthook.yml .lefthook.yml captainhook.json .pre-commit-config.yaml .husky/pre-commit 2>/dev/null || echo "No hook framework configured"
```

Then install based on what's found:
- `lefthook.yml` → `lefthook install` (or `make setup`)
- `captainhook.json` → `composer install` (auto)
- `.husky/` → `npm install` (auto)
- `.pre-commit-config.yaml` → `pre-commit install`
- Nothing → suggest adding one based on project language

## Updating Hook Versions (`pre-commit autoupdate`)

`pre-commit autoupdate` bumps every hook's `rev` to the repo's **latest tag —
including pre-releases**. It happily pins a beta (observed: isort
`8.0.1 → 9.0.0b1`). After running it, review each bumped `rev` and pin any
`aN`/`bN`/`rcN` back to the latest stable tag before committing. When a hook
mirrors a locked dev dependency (black, isort), keep the hook `rev` aligned
with the lockfile version instead of blindly taking the newest tag.

## Recommended Hooks by Stage

### pre-commit (fast, <5s)
- Code formatting (gofmt, php-cs-fixer, prettier)
- Import sorting
- YAML/JSON validation
- Secret detection

### commit-msg
- Conventional commits validation
- DCO sign-off enforcement
- Minimum message length

### pre-push (can be slower)
- Full linting (golangci-lint, phpstan)
- Smoke tests
- Security scanning

## Rules for Agents

- NEVER skip hooks with `--no-verify`
- If a hook fails, fix the underlying issue
- If hooks aren't installed, install them before first commit
- If no hook framework exists, suggest adding one in the PR

## Hooks Are Fast Feedback — CI Is the Gate

Local hooks are per-checkout, individually bypassable, and **absent in fresh
clones and in most secondary worktrees**. Treat them as fast feedback, not as an
enforcement boundary. The actual gate must be CI: every substantive check a hook
runs locally (format, lint, static analysis, tests, secret scan, commit-message
validation) needs an equivalent job in the pipeline. A check that runs only in a
local hook is silently unenforced for anyone who never installed it. When
auditing a repo, confirm that parity — a missing local hook is only a real gap
if CI doesn't cover the same check.

This also means it is legitimate to deliberately leave a repo with **no** local
hooks when the hook can't run reliably outside its container (e.g. a pre-commit
that needs a Docker-only service) — provided CI runs the equivalent check.
Forcing such a hook onto every checkout just turns it into a landmine.

## Auditing Installed Hooks (`--git-path` cwd gotcha)

To find where a checkout's hooks live, prefer the path git computes itself:

```bash
cd "$repo" && git rev-parse --git-path hooks
```

**Run it from inside the repo.** For a plain (non-worktree) clone,
`git rev-parse --git-path hooks` returns a path **relative to the current
directory** (`.git/hooks`). Resolve or `find` it from elsewhere and you look in
the wrong place and false-report "no hooks installed". (Worktrees and a
configured `core.hooksPath` return absolute paths, which masks the bug — so it
only bites on ordinary clones.) `cd` into the repo first, or resolve the path
against the repo root, before inspecting it.

## Troubleshooting

### CaptainHook + git worktrees (FAQ)

- **Symptom**: `composer install` fails with
  `Shiver me timbers! CaptainHook could not install yer git hooks! (invalid .git path)`
  when run in a secondary git worktree.
- **Cause**: Git worktrees use a `.git` *pointer file* (e.g. `gitdir: /path/to/bare/worktrees/NAME`),
  not a directory. `captainhook/hook-installer` ≤ 1.x does not resolve the pointer correctly
  and aborts.
- **Fix (recommended)**: `mkdir -p "$(git rev-parse --git-path hooks)" && composer install` —
  creates the hooks dir at the effective hooks path (honors `core.hooksPath` if configured,
  falls back to `<git-dir>/hooks` otherwise). Works with captainhook's plugin in place, so other
  Composer plugins (phpstan/extension-installer, TYPO3 composer installers, etc.) continue to
  auto-register normally.
- **Fix (last-resort fallback)**: `composer install --no-plugins` — only if the hooks-dir
  workaround above doesn't resolve it. Be aware this disables *all* Composer plugins for that
  install, which has broader side effects: phpstan extensions won't auto-register, TYPO3
  composer installers won't place extensions, and captainhook itself won't install hooks. Hooks
  still work in the primary worktree where `.git` is a real directory.
- **When this matters**: Repos using a bare-repo + worktrees layout (see
  [git-worktree(1)](https://git-scm.com/docs/git-worktree)) hit this on every `composer install`
  in a secondary worktree, since `.git` is a pointer file rather than a directory.
- **Cross-reference**: The `netresearch/typo3-ci-workflows` meta-package bundles
  `captainhook/hook-installer`; its README section "Git Worktree + captainhook Workaround"
  is the canonical source.

### Hooks fail in worktrees / hang on host-unreachable services (FAQ)

- **Symptom A**: `git commit` in a secondary worktree fails with
  `./bin/captainhook: not found` — even though `--no-verify` was passed to
  `git commit`.
- **Cause A**: hooks installed by the primary checkout run with the worktree as
  CWD and reference `./bin/captainhook` relatively; the worktree has no
  `vendor/`/`bin/`. The commit-level `--no-verify` has a blind spot:
  it skips only `pre-commit` and `commit-msg` — **`prepare-commit-msg` always
  runs**, so a broken hook of that type still fails the commit. (`git push`
  has its *own* `--no-verify`, which does skip `pre-push` entirely; the
  commit-level flag simply does not cover it.)
- **Symptom B**: a pre-commit hook that runs the test suite hangs forever on
  the host because the tests need a docker-only service (e.g. a test DB only
  resolvable inside the compose network). Killing the runner can leave a
  zombie process holding the index lock. Note that in a worktree `.git` is a
  pointer **file**, not a directory — the lock lives at
  `$(git rev-parse --git-dir)/index.lock`. First confirm no git or hook
  process is still alive (`pgrep -fl 'git|captainhook'`); only then remove
  the stale lock and retry — deleting it under a live process corrupts the
  index.
- **Controlled bypass** (the only sanctioned exception to "never skip hooks"):
  first run the hook's checks *manually via equivalent commands* (linters and
  static analysis on the changed files, the test suite inside its docker
  environment), then bypass the broken hook explicitly and disclose it:
  `git -c core.hooksPath="$(mktemp -d)" commit -s ...` (an empty hooks
  directory disables all hook types for that one command and — unlike
  `/dev/null` — is portable to Windows) and `git push --no-verify`. Never
  make the bypass the default; fix the hook environment or commit from the
  primary checkout when possible.

### Fresh worktree: missing deps and stale `hooksPath`

A freshly-created worktree often breaks pre-commit/pre-push hooks — and can even
abort the worktree creation itself:

- It has no `vendor/`/`node_modules`, so a hook binary (`vendor/bin/grumphp`,
  `captainhook`, a husky script) is missing.
- A stale or broken `core.hooksPath` points at a nonexistent binary in **another**
  worktree.

Either failure aborts worktree-add, commits, and pushes. Bypass cleanly and
**scoped** — don't disable hooks globally:

```bash
git -c core.hooksPath=/dev/null commit -s ...   # scoped to this one command
git push --no-verify
```

(`core.hooksPath="$(mktemp -d)"` is the Windows-portable equivalent — see the
controlled-bypass note above.) CI is authoritative for these repos (see "Hooks
Are Fast Feedback — CI Is the Gate"), so a scoped bypass here is safe. Also: in a
fresh worktree, `Read` a file before `Write`/`Edit` — there is no cached state
for a path the tooling has not seen yet.

### pre-commit first run: slow env build, lost stash on interrupt

The **first** commit that triggers `pre-commit` builds a fresh virtualenv for
every hook repo (ruff, markdownlint, shellcheck, …). That can take minutes, and
it is easy to interrupt or time out that commit before it finishes.

`pre-commit` stashes your **unstaged** changes for the duration of the run, then
restores them at the end. If the run is killed mid-way, that restore may not
happen — the unstaged edits silently vanish from the working tree. So **always
`git status` after an interrupted commit**, and if files reverted, reapply the
stash patch pre-commit left behind:

```bash
# pre-commit's cache dir is configurable: PRE_COMMIT_HOME, else XDG_CACHE_HOME/pre-commit,
# else ~/.cache/pre-commit (macOS/other platforms may differ).
PCH="${PRE_COMMIT_HOME:-${XDG_CACHE_HOME:-$HOME/.cache}/pre-commit}"
PATCH=$(ls -t "$PCH"/patch* 2>/dev/null | head -1)   # newest patch<epoch>-<pid>
git apply "$PATCH"
```

Then re-run the commit (the hook envs are now built, so it is fast).

### Formatter hooks rewrite files — the first commit always bounces

A hook that *reformats* rather than merely reports (`black`, `isort`,
`ruff format`, `prettier`, `shfmt`, `end-of-file-fixer`) rewrites the staged
file and then **fails the commit**, because what it wrote is not what you
staged:

```
black....................................................................Failed
- hook id: black
- files were modified by this hook
reformatted tests/test_completion.py
```

The commit did **not** happen. The fix is `git add` the now-reformatted files
and commit again — the second run passes because the file is already formatted.
Budget two `commit` invocations, and never `--amend` here (see
"Never amend a commit with pre-commit-hook failures" in
`commit-conventions.md`): the first commit does not exist, so `--amend` would
rewrite the *previous* one.

To avoid the bounce entirely, run the formatter before committing — matching
whatever the repo actually uses, which is not always the one you expect:

```bash
# read the hook ids the repo declares, then run those
yq '.repos[].hooks[].id' .pre-commit-config.yaml
pre-commit run black isort --files <changed files>   # or: ruff format . && ruff check .
```

Checking the config matters: a project can use `black`+`isort` where you assumed
`ruff format`, and a habit built around only one of them still bounces on every
commit in the other.

### `--no-verify` only after confirming CI parity

A local hook the CI pipeline does **not** run is not a real merge gate (see
"Hooks Are Fast Feedback — CI Is the Gate"). If such a hook (say a repo-only
`black`, `isort`, or `shellcheck`) reports the tree dirty and running its
formatter would rewrite **hundreds of unrelated lines**, bypassing it with
`--no-verify` is defensible — but only *after* you have read the CI workflow and
confirmed it does not enforce that check. Concretely: verify the pipeline's
`flake8` uses a narrow `--select`, that there is no `shellcheck`/`black` job,
etc. A hook enforced only locally is already silently unenforced — don't let it
dictate a massive diff that has nothing to do with your change. If CI *does* run
the check, it is a real gate: fix the finding instead of bypassing it.
