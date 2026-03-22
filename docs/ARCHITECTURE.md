# Architecture

## Overview

The git-workflow-skill is an Agent Skill package that provides procedural knowledge about Git workflows to AI coding agents. It follows the [Agent Skills specification](https://agentskills.io) for cross-platform compatibility.

## Skill Structure

The skill uses a layered content architecture:

1. **SKILL.md** (`skills/git-workflow/SKILL.md`) -- Entry point loaded by the agent runtime. Contains metadata (name, version, triggers, allowed tools) and a condensed quick reference. Defines content triggers that tell the agent which reference file to load for a given task.

2. **References** (`skills/git-workflow/references/`) -- Detailed procedural knowledge split by domain (branching, commits, PRs, CI/CD, releases, advanced operations, code quality). Loaded on-demand based on content triggers to keep context window usage efficient.

3. **Scripts** (`skills/git-workflow/scripts/`) -- Executable verification scripts that validate a project's git workflow configuration.

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
