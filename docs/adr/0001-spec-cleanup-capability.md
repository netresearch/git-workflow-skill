# ADR 0001 — Spec-Cleanup Capability

**Status:** Accepted, implemented
**Date:** 2026-06-16 (decision) / 2026-08-07 (recorded as ADR)
**Supersedes:** `docs/superpowers/specs/2026-06-16-spec-cleanup-design.md`, removed in the same change

## Context

Agent sessions produce intermediate planning artifacts — superpowers specs and
plans, ad-hoc `PLAN.md`, planning-tool output. They are working material: useful
while the work is in flight, noise once it lands. Without a gate they ride along
into the base branch, where nobody prunes them because nobody is sure they are
dead.

The behaviour that resulted is documented in
[`skills/git-workflow/references/spec-cleanup.md`](../../skills/git-workflow/references/spec-cleanup.md);
this record keeps the decisions and the boundaries, which a how-to page is the
wrong place for.

## Decision

A two-layer capability inside `git-workflow-skill`, wired into `/pr-finish`
before the rebase step:

1. **Guard** (`scripts/spec-cleanup-guard.sh`) — deterministic, read-only.
   Detects artifacts in all three states: tracked, staged, and untracked.
2. **Capture** — assisted and proposal-only. Converts durable decisions into a
   doc or ADR for review, then removes the raw files through git.

Detection is anchored to declared globs, extensible per repo via
`.spec-cleanup.yml`, with the folder taxonomy declared in `AGENTS.md`.

## Boundaries, and why

- **No heuristic auto-discovery as a deletion driver.** Enforced detection runs
  only against declared globs. Session context may *discover and register* a
  stray artifact, never silently drive its removal. A heuristic that deletes is
  a heuristic that eventually deletes the wrong thing.
- **Every removal is recoverable.** Removal goes through git — an untracked file
  is `git add`ed so it enters history, then `git rm`ed in a visible commit.
  Never a bare `rm`, which puts the content beyond reach of the tool that is
  supposed to make the operation reversible.
- **Never auto-write documentation.** Capture proposes; a human accepts. The
  cost of a wrong silent doc is higher than the cost of a prompt.
- **A no-op on a clean branch.** A branch with no artifacts sees nothing — no
  output, no prompt, no ceremony. A gate that fires cosmetically gets ignored,
  and then it is not a gate.
- **Not a standalone skill.** It lives in `git-workflow-skill` because it is a
  step in the PR lifecycle, not a subject of its own.
- **Composes with, does not replace,** the existing merge gate and reviewer
  flows.

## Consequences

- `/pr-finish` gains a step that can block on unresolved artifacts, with three
  exits: convert to a durable doc, remove recoverably, or acknowledge via a
  `Spec-Cleanup: acknowledged` trailer.
- Repos opt in by declaring their taxonomy; without a declaration the guard
  falls back to shipped defaults and stays quiet on repos that keep no such
  folders.
- The guard reports artifacts already present on the base branch, including ones
  no current PR introduced. That is intentional — it surfaces them — but it means
  a hit is not automatically the current PR's problem. This ADR's own source spec
  was such a hit.
