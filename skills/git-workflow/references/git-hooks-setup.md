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

## Troubleshooting

### CaptainHook + git worktrees (FAQ)

- **Symptom**: `composer install` fails with
  `Shiver me timbers! CaptainHook could not install yer git hooks! (invalid .git path)`
  when run in a secondary git worktree.
- **Cause**: Git worktrees use a `.git` *pointer file* (e.g. `gitdir: /path/to/bare/worktrees/NAME`),
  not a directory. `captainhook/hook-installer` ≤ 1.x does not resolve the pointer correctly
  and aborts.
- **Fix (recommended)**: `composer install --no-plugins` — skips captainhook's hook install
  (and any other composer plugins). Hooks still work in the primary worktree where `.git` is
  a real directory.
- **Fix (alternative)**: `mkdir -p "$(git rev-parse --git-dir)/hooks" && composer install` —
  creates the hooks dir at the actual git-dir location. May or may not work depending on the
  captainhook version; try `--no-plugins` first.
- **When this matters**: Netresearch extension repos use a bare-repo + worktrees layout
  (see the "Git Worktree Convention" in the user's global `CLAUDE.md`). Most dev work happens
  in feature-branch worktrees where this fires on every `composer install`.
- **Cross-reference**: The `netresearch/typo3-ci-workflows` meta-package bundles
  `captainhook/hook-installer`; its README section "Git Worktree + captainhook Workaround"
  is the canonical source.
