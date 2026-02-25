---
name: git-workflow
description: "Use when establishing branching strategies, implementing Conventional Commits, creating or reviewing PRs, managing PR review threads, merging PRs with signed commits, handling merge conflicts, or integrating Git with CI/CD."
---

# Git Workflow Skill

Expert patterns for Git version control: branching, commits, collaboration, and CI/CD.

## Expertise Areas

- **Branching**: Git Flow, GitHub Flow, Trunk-based development
- **Commits**: Conventional Commits, semantic versioning
- **Collaboration**: PR workflows, code review, merge strategies, thread resolution
- **CI/CD**: GitHub Actions, GitLab CI, branch protection

## Reference Files

Detailed documentation for each area:

| Reference | When to Load |
|-----------|--------------|
| `references/branching-strategies.md` | Managing branches, choosing branching model |
| `references/commit-conventions.md` | Writing commits, semantic versioning |
| `references/pull-request-workflow.md` | Creating/reviewing PRs, thread resolution, merging |
| `references/ci-cd-integration.md` | CI/CD automation, GitHub Actions |
| `references/advanced-git.md` | Rebasing, cherry-picking, bisecting |
| `references/github-releases.md` | Release management, immutable releases |
| `references/code-quality-tools.md` | Shell linting, formatting, smart fixups, structural diffs |

### Explicit Content Triggers

When creating pull requests, load `references/pull-request-workflow.md` for PR structure, size guidelines, and template patterns.

When reviewing PRs or responding to review comments, load `references/pull-request-workflow.md` for review comment levels (blocking/suggestion/nit) and the code review checklist.

When replying to PR review threads or resolving threads, load `references/pull-request-workflow.md` for the GraphQL API patterns for thread replies and resolution.

When merging PRs, load `references/pull-request-workflow.md` for the merge requirements checklist (resolved threads, Copilot review, rebased branch, CI checks).

When merging in repos requiring signed commits with rebase-only strategy, load `references/pull-request-workflow.md` for the local fast-forward merge workflow.

When handling merge conflicts, load `references/pull-request-workflow.md` for conflict resolution strategies.

When choosing a branching strategy, load `references/branching-strategies.md` for Git Flow, GitHub Flow, and Trunk-based patterns.

When writing commit messages, load `references/commit-conventions.md` for Conventional Commits format and semantic versioning rules.

When creating releases, load `references/github-releases.md` for immutable release warnings and recovery patterns.

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

## Code Quality Tools

### shellcheck - Shell Script Linter

Static analysis for bash/sh/zsh scripts. Catches common bugs, quoting issues, and portability problems.

```bash
# Lint a script
shellcheck script.sh

# Lint all shell scripts in repo
fd -e sh -e bash | xargs shellcheck

# Specify shell dialect
shellcheck --shell=bash script.sh

# Exclude specific rules
shellcheck --exclude=SC2086 script.sh
```

**Rule:** Always run `shellcheck` on shell scripts before committing. Catches real bugs that cause CI failures.

### shfmt - Shell Script Formatter

Consistent formatting for shell scripts (like gofmt for Go).

```bash
# Format in-place with 2-space indent
shfmt -w -i 2 script.sh

# Format all shell scripts
fd -e sh -e bash | xargs shfmt -w -i 2

# Check formatting without modifying (CI mode)
shfmt -d -i 2 script.sh

# Use EditorConfig settings
shfmt -w .
```

**Rule:** Run `shfmt -w -i 2` on shell scripts for consistent formatting.

### git-absorb - Smart Fixup Commits

Automatically creates fixup commits and absorbs them into the correct parent commits. Replaces the manual workflow of `git commit --fixup=<SHA>` + `git rebase --autosquash`.

```bash
# Stage your fixes, then absorb
git add -p           # Stage changes
git absorb           # Auto-create fixup commits for correct parents
git rebase --autosquash main  # Apply the fixups

# Or with auto-rebase
git absorb --and-rebase
```

**When to use:** After code review, when you have fixes that belong to specific earlier commits. Instead of manually identifying which commit each fix belongs to, git-absorb figures it out automatically.

### difft (difftastic) - Structural Diff

Syntax-aware diff that understands code structure. Shows meaningful changes, ignores formatting.

```bash
# One-time use (no config change)
GIT_EXTERNAL_DIFF=difft git diff

# Configure permanently as default git diff tool
git config diff.external difft

# Compare two files directly
difft old_file.py new_file.py

# Use with git log (one-time)
GIT_EXTERNAL_DIFF=difft git log -p --ext-diff

# Use with git log (when configured permanently)
git log -p --ext-diff
```

**When to use:** When reviewing changes that mix formatting with logic changes. difft separates structural changes from whitespace/formatting noise.

## Verification

```bash
./scripts/verify-git-workflow.sh /path/to/repository
```

## GitHub Immutable Releases

**CRITICAL**: Deleted releases block tag names PERMANENTLY. Get releases right first time.

See `references/github-releases.md` for prevention and recovery patterns.

---

> **Contributing:** https://github.com/netresearch/git-workflow-skill
