---
name: git-workflow
description: "Use when establishing branching strategies, implementing Conventional Commits, creating or reviewing PRs, resolving PR review comments, merging PRs (including CI verification, auto-merge queues, and post-merge cleanup), managing PR review threads, merging PRs with signed commits, handling merge conflicts, creating releases, or integrating Git with CI/CD."
license: "(MIT AND CC-BY-SA-4.0). See LICENSE-MIT and LICENSE-CC-BY-SA-4.0"
compatibility: "Requires git, gh CLI."
metadata:
  author: Netresearch DTT GmbH
  version: "1.12.0"
  repository: https://github.com/netresearch/git-workflow-skill
allowed-tools: Bash(git:*) Bash(gh:*) Read Write
---

# Git Workflow Skill

Expert patterns for Git version control: branching, commits, collaboration, and CI/CD.

## Critical Rules (Non-Negotiable)

1. **No direct push to main** — always open a PR.
2. **No merge before all review threads are resolved** — run the merge gate in `references/pull-request-workflow.md`.
3. **No squash unless user asked** — atomic commits preserved; keeps GPG signatures and bisection.
4. **No "tested/verified/working" without pasted command output** — if you cannot run the check, say so.
5. **No edits to installed skill/plugin cache paths** (`~/.claude/skills/`, `~/.claude/plugins/cache/`, `**/.bare/**`) — always the repo worktree. Verify `pwd` first.
6. **Force-push only with `--force-with-lease`** — never plain `--force`.

See `references/pull-request-workflow.md` for the merge-gate command, atomic-commit guidance, and review-thread SHA-citation pattern.

## Reference Files

Load references on demand based on the task at hand:

| Reference | Content Triggers |
|-----------|-----------------|
| `references/branching-strategies.md` | Branching model, Git Flow, GitHub Flow, trunk-based, branch protection |
| `references/commit-conventions.md` | Commit messages, conventional commits, semantic versioning, commitlint |
| `references/pull-request-workflow.md` | PR create/review/merge, thread resolution, merge strategies, CODEOWNERS, signed commits + rebase |
| `references/ci-cd-integration.md` | GitHub Actions, GitLab CI, semantic release, deployment |
| `references/advanced-git.md` | Rebase, cherry-pick, bisect, stash, worktrees, reflog, submodules, recovery |
| `references/github-releases.md` | Release management, immutable releases, `--latest=false`, multi-branch |
| `references/git-hooks-setup.md` | Hook frameworks, detection, recommended hooks per stage |
| `references/claude-code-hooks.md` | Claude Code `settings.json` hooks — merge gate, cache-path rejection, auto-lint |
| `references/code-quality-tools.md` | shellcheck, shfmt, git-absorb, difftastic |

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

Before first commit, detect and install hooks:

```bash
ls lefthook.yml .lefthook.yml captainhook.json .pre-commit-config.yaml .husky/pre-commit 2>/dev/null || echo "No hooks"
```

Install: lefthook.yml -> `lefthook install` | captainhook.json -> `composer install` | .husky/ -> `npm install` | .pre-commit-config.yaml -> `pre-commit install`

## Critical Release Rules

1. **Immutable releases**: Deleted releases permanently block tag reuse; bump version instead.
2. **Multi-branch releases**: Use `--latest=false` from non-default branches.
3. **Pre-release**: Version bumped, CI green, CHANGELOG updated, `git pull` BEFORE `gh release create`.

## PR Merge Requirements

Before merging: all threads resolved, CI checks green (including annotations), branch rebased, commits signed (if required). For signed commits + rebase-only repos, use local `git merge --ff-only`.

## Verification

```bash
./scripts/verify-git-workflow.sh /path/to/repository
```

---

> **Contributing:** https://github.com/netresearch/git-workflow-skill
