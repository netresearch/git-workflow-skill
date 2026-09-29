<!-- SPDX-License-Identifier: CC-BY-SA-4.0 -->
<!-- SPDX-FileCopyrightText: Netresearch DTT GmbH -->

# Architecture

## Overview

The git-workflow-skill is an Agent Skill package that provides procedural knowledge about Git workflows to AI coding agents. It follows the [Agent Skills specification](https://agentskills.io) for cross-platform compatibility.

## Skill Structure

The skill uses a layered content architecture:

1. **SKILL.md** (`skills/git-workflow/SKILL.md`) -- Entry point loaded by the agent runtime. Contains metadata (name, version, triggers, allowed tools) and a condensed quick reference. Defines content triggers that tell the agent which reference file to load for a given task.

2. **References** (`skills/git-workflow/references/`) -- Detailed procedural knowledge split by domain (branching, commits, PRs, CI/CD, releases, advanced operations, code quality). Loaded on-demand based on content triggers to keep context window usage efficient.

3. **Scripts** (`skills/git-workflow/scripts/`) -- Executables that the agent runs, or that a Claude Code hook runs, against the user's repository and pull requests. They fall into four groups:

   | Group | Script | What it does |
   | --- | --- | --- |
   | Verification | `verify-git-workflow.sh` | Reports on branch naming, commit message format, `.gitignore`, hooks, code ownership, PR templates, CI/CD and release configuration, conflict markers and commit signing |
   | Verification | `spec-cleanup-guard.sh` | Read-only gate: reports intermediate planning artifacts that must not reach the base branch (exit 1 when found) |
   | Preflight | `repo-contribution-preflight.sh` | Collects a repository's contribution rules (README, contribution docs, templates, export rules, CI) before the first artifact |
   | Preflight | `signing-preflight.sh` | Proves whether `git commit -S` writes a signature, with a probe commit on a throwaway branch and a temporary index |
   | Pull requests (GitHub) | `pr-status.sh` | Merge readiness of a pull request and the next valid action, printed as a command it does not run; `--watch` returns on the next actionable event |
   | Pull requests (GitHub) | `pr-merge.sh` | Merges a pull request with a method the repository allows, only when the gate is open, and reads the pull request back to confirm |
   | Hook gates | `merge-gate.sh` | PreToolUse hook: denies `gh pr merge` while review threads are unresolved or the merge state is not `CLEAN` |
   | Hook gates | `conflict-marker-gate.py` | PreToolUse hook: denies `git commit` while staged content carries merge-conflict markers |

   `pr-merge.sh` is the only script that changes remote state. The hook gates are wired by the user (see `references/claude-code-hooks.md`); the plugin's own `hooks/hooks.json` runs `scripts/validate_git_command.py` from the repository root instead.

## Content Flow

```
Agent receives task
  → SKILL.md loaded (always)
  → Content trigger matched (e.g., "PR operations")
  → Relevant reference loaded (e.g., pull-request-workflow.md)
  → Agent applies patterns from reference
```

## Build Infrastructure

- **Build/hooks/** -- Git hook templates (pre-commit, pre-push) for local development
- **Build/Scripts/** -- CI validation scripts (plugin version checks, skill validation)
- **.envrc** -- direnv configuration that auto-configures git hooksPath

## Distribution

The skill is distributed via multiple channels:
- GitHub releases (`.tar.gz` archives)
- Composer package (`netresearch/git-workflow-skill`)
- Direct git clone
- npx skills CLI
