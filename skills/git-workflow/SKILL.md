---
name: git-workflow
description: "Use when establishing branching strategies, implementing Conventional Commits, creating or reviewing PRs, resolving PR review comments, merging PRs (including CI verification, auto-merge queues, and post-merge cleanup), managing PR review threads, merging PRs with signed commits, handling merge conflicts, creating releases, integrating Git with CI/CD, setting up git hooks (lefthook, captainhook, husky, pre-commit), or debugging hook-install failures in git worktrees."
license: "(MIT AND CC-BY-SA-4.0). See LICENSE-MIT and LICENSE-CC-BY-SA-4.0"
compatibility: "Requires git, gh CLI; yq for .spec-cleanup.yml."
metadata:
  author: Netresearch DTT GmbH
  version: "1.18.3"
  repository: https://github.com/netresearch/git-workflow-skill
allowed-tools: Bash(git:*) Bash(gh:*) Read Write
---

# Git Workflow Skill

## Critical Rules (Non-Negotiable)

1. **No direct push to main** — always open a PR.
2. **No merge before all threads resolved** — see `references/pull-request-workflow.md`.
3. **No squash unless asked** — preserves atomic commits, signatures, bisection.
4. **No "tested/verified/working" without pasted command output** — else say so.
5. **No edits to installed skill/plugin cache paths** (`~/.claude/skills/`, `~/.claude/plugins/cache/`, `**/.bare/**`) — always the repo worktree, verified by `pwd`.
6. **Force-push only with `--force-with-lease`** — never plain `--force`.
7. **Commit before rebase** — `add → commit → fetch → rebase → push`. Dirty tree aborts rebase.
8. **No editorializing** — state what changed, not how good it is; no narrating expected results or self-praise. See `references/no-editorializing.md`.

See `references/pull-request-workflow.md` for merge-gate and atomic-commit patterns.

## Reference Files

Load on demand:

| Reference | Content Triggers |
|-----------|-----------------|
| `references/branching-strategies.md` | Branching models, Git/GitHub Flow, trunk-based, protection |
| `references/commit-conventions.md` | Conventional commits, DCO sign-off, semantic versioning, commitlint |
| `references/pull-request-workflow.md` | PR create/review/merge, threads, strategies, CODEOWNERS, signed rebase |
| `references/ci-cd-integration.md` | GitHub Actions, GitLab CI, semantic release, deployment |
| `references/advanced-git.md` | Rebase, cherry-pick, bisect, stash, worktrees, reflog, recovery |
| `references/github-releases.md` | Immutable releases, `--latest=false`, multi-branch |
| `references/git-hooks-setup.md` | Hook frameworks, detection, hooks per stage |
| `references/claude-code-hooks.md` | Claude Code `settings.json` hooks — merge gate, cache-path rejection, auto-lint |
| `references/code-quality-tools.md` | shellcheck, shfmt, git-absorb, difftastic |
| `references/merge-gate-watcher.md` | Merge-driver loop, check taxonomy, stale-SHA rerun, review-bot rounds |
| `references/spec-cleanup.md` | Keep planning artifacts off the base branch; guard + capture-to-ADR |
| `references/no-editorializing.md` | Writing without self-praise or narrating the expected |

## Conventional Commits

```
<type>[scope]: <description>
```

**Types**: `feat` (MINOR), `fix` (PATCH), `docs`, `style`, `refactor`, `perf`, `test`, `build`, `ci`, `chore`, `revert`

**Breaking change**: Add `!` after type or `BREAKING CHANGE:` in footer.

## Branch Naming

```
feature/TICKET-123-description
fix/TICKET-456-bug-name
release/1.2.0
hotfix/1.2.1-security-patch
```

## Hook Detection

Detect hooks first:

```bash
ls lefthook.yml .lefthook.yml captainhook.json .pre-commit-config.yaml .husky/pre-commit 2>/dev/null || echo "No hooks"
```

Install: `lefthook install` | `composer install` | `npm install` | `pre-commit install`

## Critical Release Rules

1. **Immutable releases**: deleted releases block tag reuse; bump version.
2. **Multi-branch releases**: Use `--latest=false` from non-default branches.
3. **Pre-release**: Version bumped, CI green, CHANGELOG updated, `git pull` BEFORE `gh release create`.

## PR Merge Requirements

Before merging: threads resolved, CI green (incl. annotations), rebased, signed. Rebase-only + signed: `git merge --ff-only`.

## Verification

```bash
./scripts/verify-git-workflow.sh /path/to/repository
```

---

> **Contributing:** <https://github.com/netresearch/git-workflow-skill>
