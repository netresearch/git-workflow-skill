---
name: git-workflow
description: "Use when establishing branching strategies, implementing Conventional Commits, creating or reviewing PRs, resolving PR review comments, merging PRs (including CI verification, auto-merge queues, and post-merge cleanup), managing PR review threads, merging PRs with signed commits, handling merge conflicts, rebasing a long-lived branch onto a moved base or splitting one into several PRs, integrating Git with CI/CD, setting up git hooks (lefthook, captainhook, husky, pre-commit), or debugging hook-install failures in git worktrees. Not for creating releases (use github-release) or diagnosing BLOCKED/won't-merge PRs (use github-project)."
license: "(MIT AND CC-BY-SA-4.0). See LICENSE-MIT and LICENSE-CC-BY-SA-4.0"
compatibility: "Requires git, gh CLI; yq for .spec-cleanup.yml."
metadata:
  author: Netresearch DTT GmbH
  version: "1.26.0"
  repository: https://github.com/netresearch/git-workflow-skill
allowed-tools: Bash(git:*) Bash(gh:*) Read Write
---

# Git Workflow Skill

## When to Use

- Branching, Conventional Commits; PRs: open, review, resolve threads, merge (CI gate, queues, cleanup)
- Conflicts, rebasing a long-lived branch, splitting a PR, git hooks (incl. worktree installs)
- **Not here**: releases (`github-release`); BLOCKED-PR diagnosis (`github-project`)

## Critical Rules (Non-Negotiable)

1. **No direct push to main** — always open a PR.
2. **No merge before all threads resolved** (`references/pull-request-workflow.md`).
3. **No squash unless asked** — preserves atomic commits, signatures, bisection.
4. **No "tested/verified/working" without pasted command output** — else say so.
5. **No edits to installed skill/plugin cache paths** (`~/.claude/skills/`, `~/.claude/plugins/cache/`, `**/.bare/**`) — always the repo worktree, verified by `pwd`.
6. **Force-push only with `--force-with-lease`** — never plain `--force`.
7. **Commit before rebase** — `add → commit → fetch → rebase → push` (a dirty tree aborts it).
8. **No editorializing** — state what changed, not how good it is (`references/no-editorializing.md`).

## Reference Files

| Reference | Content Triggers |
|-----------|-----------------|
| `references/commit-conventions.md` | Conventional commits, DCO sign-off |
| `references/pull-request-workflow.md` | PR merge gate, signed rebase |
| `references/ci-cd-integration.md` | CI watching, git mirrors |
| `references/advanced-git.md` | Rebase, cherry-pick, bisect, stash, worktrees, reflog |
| `references/github-releases.md` | → `github-release` skill |
| `references/git-hooks-setup.md` | Hook frameworks, hooks per stage |
| `references/claude-code-hooks.md` | `settings.json` merge gate, cache-path rejection, auto-lint |
| `references/code-quality-tools.md` | shellcheck, shfmt, git-absorb, difftastic |
| `references/merge-gate-watcher.md` | Merge-driver loop, check taxonomy, stale-SHA rerun |
| `references/spec-cleanup.md` | Planning artifacts off the base branch |
| `references/no-editorializing.md` | No self-praise, no narrating the expected |

## Conventional Commits

```
<type>[scope]: <description>
```

**Types**: `feat` (MINOR), `fix` (PATCH), `docs`, `style`, `refactor`, `perf`, `test`, `build`, `ci`, `chore`, `revert`

**Breaking change**: Add `!` after type or `BREAKING CHANGE:` in footer.

**Branches**: `feature/TICKET-123-description`, `release/1.2.0`

## Hook Detection

```bash
ls lefthook.yml .lefthook.yml captainhook.json .pre-commit-config.yaml .husky/pre-commit 2>/dev/null || echo "No hooks"
```

Install: `lefthook install`, `composer install`, `npm install`, `pre-commit install`

## PR Merge Requirements

Before merging: threads resolved, CI green (incl. annotations), rebased, signed, **and reviewed** (human or bot, on the current head). Rebase-only + signed: `git merge --ff-only`.

## Verification

```bash
./scripts/verify-git-workflow.sh /path/to/repository
# Gate state, next action:
./scripts/pr-status.sh [-R owner/repo] [PR] [--json] [--watch]
# Merge; refuses when the gate is shut:
./scripts/pr-merge.sh [-R owner/repo] [PR] [--dry-run|--self-reviewed]
```

---

> **Contributing:** <https://github.com/netresearch/git-workflow-skill>
