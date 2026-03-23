---
name: git-workflow
description: "Use when establishing branching strategies, implementing Conventional Commits, creating or reviewing PRs, resolving PR review comments, merging PRs (including CI verification, auto-merge queues, and post-merge cleanup), managing PR review threads, merging PRs with signed commits, handling merge conflicts, creating releases, or integrating Git with CI/CD."
license: "(MIT AND CC-BY-SA-4.0). See LICENSE-MIT and LICENSE-CC-BY-SA-4.0"
compatibility: "Requires git, gh CLI."
metadata:
  author: Netresearch DTT GmbH
  version: "1.9.0"
  repository: https://github.com/netresearch/git-workflow-skill
allowed-tools: Bash(git:*) Bash(gh:*) Read Write
---

# Git Workflow Skill

Expert patterns for Git version control: branching, commits, collaboration, and CI/CD.

## Expertise Areas

- **Branching**: Git Flow, GitHub Flow, Trunk-based development
- **Commits**: Conventional Commits, semantic versioning
- **Collaboration**: PR workflows, code review, merge strategies, thread resolution
- **CI/CD**: GitHub Actions, GitLab CI, branch protection

## Reference Files

| Reference | When to Load |
|-----------|--------------|
| `references/branching-strategies.md` | Managing branches, choosing branching model |
| `references/commit-conventions.md` | Writing commits, semantic versioning |
| `references/pull-request-workflow.md` | Creating/reviewing PRs, thread resolution, merging |
| `references/ci-cd-integration.md` | CI/CD automation, GitHub Actions |
| `references/advanced-git.md` | Rebasing, cherry-picking, bisecting |
| `references/github-releases.md` | Release management, immutable releases |
| `references/git-hooks-setup.md` | Hook frameworks, detection, recommended hooks |
| `references/code-quality-tools.md` | Shell linting, formatting, smart fixups, structural diffs |

### Content Triggers

- **PR operations** (create, review, merge, thread resolution, conflicts, CI checks): load `references/pull-request-workflow.md`
- **Branching strategy**: load `references/branching-strategies.md`
- **Commit messages**: load `references/commit-conventions.md`
- **Releases**: load `references/github-releases.md`
- **Git hooks**: detect with `ls lefthook.yml captainhook.json .pre-commit-config.yaml .husky/pre-commit 2>/dev/null`. Details in `references/git-hooks-setup.md`

## Conventional Commits (Quick Reference)

```
<type>[scope]: <description>
```

**Types**: `feat` (MINOR), `fix` (PATCH), `docs`, `style`, `refactor`, `perf`, `test`, `build`, `ci`, `chore`, `revert`

**Breaking change**: Add `!` after type or `BREAKING CHANGE:` in footer.

## Branch Naming

```bash
feature/TICKET-123-description
fix/TICKET-456-bug-name
release/1.2.0
hotfix/1.2.1-security-patch
```

## GitHub Flow (Default)

```bash
git checkout main && git pull
git checkout -b feature/my-feature
# ... work ...
git push -u origin HEAD
gh pr create && gh pr merge --squash
```

Before first commit, install git hooks — see `references/git-hooks-setup.md`.

For code quality tools (shellcheck, shfmt, git-absorb, difft), see `references/code-quality-tools.md`.

## GitHub Immutable Releases

**CRITICAL**: Deleted releases block tag names PERMANENTLY. Get releases right first time.

See `references/github-releases.md` for prevention and recovery patterns.

## Verification

```bash
./scripts/verify-git-workflow.sh /path/to/repository
```

---

> **Contributing:** https://github.com/netresearch/git-workflow-skill
