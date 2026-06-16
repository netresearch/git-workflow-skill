# Spec-Cleanup Capability — Design

- **Date:** 2026-06-16
- **Status:** Draft (pending implementation plan)
- **Home:** `git-workflow-skill` (global org skill)
- **Origin:** #team-ecom discussion 2026-06-15 — superpowers spec/plan files
  (~5000 lines) committed on a feature branch (HMKG-2227) and dragged across
  branches via `develop`. Team agreed intermediate planning artifacts must not
  land in the base branch and durable knowledge should be captured first.

## 1. Problem

Dev-time planning artifacts — superpowers specs/plans (`docs/superpowers/**`),
Claude's own scratch plans, output from other planning tools — get committed to
feature branches and then carried into the base branch on merge. They are
throwaway working notes, not durable documentation, so they rot in the repo and
pollute history.

Two distinct needs, with different failure modes, were conflated in the chat:

- **Hygiene / gate** — keep throwaway planning files out of the base branch.
  Deterministic, mechanical, safe to enforce.
- **Knowledge capture** — distil durable decisions into PRD/ADR/user docs before
  the raw files are removed. Creative, judgment-heavy, must stay human-reviewed.

Bundling them into one silent "convert + remove on merge" does both badly: a
poor auto-summary becomes a false source of truth, or a skipped capture blocks
the merge. The design keeps them as two layers in one capability.

## 2. Goals / Non-Goals

**Goals**
- Block the base branch from receiving tracked intermediate artifacts.
- Catch artifacts in **all three states**: committed/tracked, staged, untracked
  working-tree files.
- Propose (never silent-write) durable docs — PRD update, ADR(s), user docs —
  from the intermediate artifacts, for human review.
- Default mode = **convert**, falling back to **remove-with-acknowledgement**.
- Ship usable defaults; let repos extend via config and declare layout in
  `AGENTS.md`.
- Be a no-op when a branch has no intermediate artifacts (no cosmetic gate).

**Non-Goals**
- Auto-discovering "every intermediate file everywhere" by heuristic. Detection
  is anchored to declared paths (Guard) plus in-session knowledge (Capture).
- Auto-writing documentation without review.
- Replacing the existing merge gate or `oro-qa-reviewer`; this composes with them.
- A standalone skill — this lives inside `git-workflow-skill`.

## 3. Architecture

Two layers, one capability, wired into the existing `/pr-finish` flow and merge
gate:

```
/pr-finish
  └─ Guard (deterministic): tracked|staged|untracked intermediate artifacts?
        ├─ none → existing merge gate → merge
        └─ some → Capture (in-session, context-aware)
                    → reads artifacts (declared globs ∪ session-known paths)
                    → proposes PRD/ADR/docs diff ──review──┐
                    → accept: commit docs + remove raw      │
                    → none/reject: acknowledge + remove raw │
                    → Guard re-check → clean → merge gate ──┘
```

### 3.1 Guard (deterministic, the enforceable net)

`scripts/spec-cleanup-guard.sh`. Context-free so it can run at the merge gate
and in CI. Given the config glob set, it reports any intermediate artifacts in
three states:

| State | Detection |
|-------|-----------|
| committed/tracked | `git ls-files -- <globs>` |
| staged | `git diff --cached --name-only -- <globs>` |
| untracked working-tree | `git ls-files --others --exclude-standard -- <globs>` |

Exit non-zero with a message listing the offending files grouped by state and
the three resolutions (convert / remove / acknowledge). Wired into:

- the **merge gate** in `references/pull-request-workflow.md` (blocks merge), and
- an **optional pre-commit hook** in `hooks/` (off by default — initial commit of
  working notes is allowed per Paul's point; opt-in for repos wanting early
  blocking per Ertner's point).

### 3.2 Capture (assisted, proposes only)

A `/pr-finish` step that runs in-session, so it can use **both** declared globs
and **conversation context** (spec/plan files the agent authored this session,
including ad-hoc `PLAN.md` or other-tool output that no static glob matches).
Detection set = `declared globs ∪ session-known artifact paths`.

It dispatches a sub-agent that **reads** the artifacts and **proposes a diff**:

- PRD update (`capture_targets.prd`, update-in-place) — if present.
- ADR(s) into the repo's existing ADR dir/numbering (`capture_targets.adr`).
- User-doc stubs (`capture_targets.docs`).

The human reviews the diff. On accept: commit the durable docs, then remove the
raw artifacts (`git rm` for tracked, `rm` for untracked). On "nothing durable":
record an explicit acknowledgement (commit trailer `Spec-Cleanup: acknowledged`)
and remove-only. Capture **never** writes docs unattended; low-confidence or
empty extraction surfaces "nothing durable found, confirm removal."

### 3.3 Config — `.spec-cleanup.yml`

Machine-readable mirror of the `AGENTS.md` layout declaration. Built-in defaults
ship in the skill, so a repo with no config still guards `docs/superpowers/**`.

```yaml
intermediate_paths:        # throwaway planning artifacts (Guard + Capture)
  - docs/superpowers/**
  - claudedocs/**
  - "**/*.plan.md"
  - docs/working/**
capture_targets:           # where durable knowledge goes; each optional
  prd:  docs/PRD.md
  adr:  docs/adr/
  docs: Documentation/
mode: convert              # convert | remove | block   (default: convert)
pre_commit_block: false    # opt-in early blocking
```

Absent `capture_targets` → Capture degrades to remove-with-acknowledgement.

### 3.4 AGENTS.md — canonical layout declaration

`AGENTS.md` gains a layout subsection distinguishing **persisted/durable** doc
folders from **intermediate/working** folders, e.g.:

```
docs/PRD.md, docs/adr/, Documentation/   # persisted — durable knowledge
docs/superpowers/, claudedocs/, docs/working/  # intermediate — never reach base
```

`AGENTS.md` is the human source of truth; `.spec-cleanup.yml` is its
machine-readable mirror. A consistency check (agent-harness "doc-drift" style)
warns when the two diverge.

## 4. Data flow / state resolution

The gate is clean only when **no** intermediate artifact remains in **any** of
the three states. Resolution paths:

1. **Convert** (default) — Capture proposes docs → human accepts → docs committed
   → raw removed.
2. **Remove** — raw removed without conversion (mode `remove`, or human declines
   conversion).
3. **Acknowledge** — human asserts nothing durable; commit trailer recorded; raw
   removed.

## 5. Error handling / edge cases

- **No config** → built-in defaults (`docs/superpowers/**`), convert mode, no
  capture targets → remove-with-ack.
- **Capture low-confidence / empty** → no auto-write; surfaces confirm-removal.
- **Reference project / empty `src/`** → no intermediate files → Guard is a no-op
  (avoids the "cosmetic stage" smell raised in the same chat).
- **Binary / very large plans** → Guard only checks path presence; Capture reads
  text and skips binaries.
- **Already-clean branch** → Guard no-op, merge proceeds normally.
- **CI context (no session)** → only the Guard runs; Capture is interactive-only.

## 6. Adoption by team repos

The `ecom-orocommerce-docker` repo adopts the capability by adding its own
`.spec-cleanup.yml` (orocommerce-specific globs + doc targets) — no forked logic.
It composes with the existing `oro-qa-reviewer` agent rather than replacing it.

## 7. Testing

Evals in `skills/git-workflow/evals/` plus a `checkpoints.yaml` entry:

- **E1** branch with `docs/superpowers/**` tracked → Guard fails, lists files by
  state.
- **E2** untracked intermediate file present → Guard fails (untracked state).
- **E3** after convert + remove → Guard passes.
- **E4** repo with no config → default Guard active on `docs/superpowers/**`.
- **E5** acknowledge path → Guard passes with removal only + trailer present.
- **E6** clean branch → Guard no-op.
- **E7** `AGENTS.md` ↔ `.spec-cleanup.yml` divergence → consistency check warns.

## 8. Delivery

- Feature PR on `git-workflow-skill` (`feature/spec-cleanup-capability`).
- No version bump / CHANGELOG entry in the feature PR (separate release flow).
- Signed commits (`git commit -s`); DCO-enforced repo.
- This design doc lives under `docs/superpowers/specs/` as intentional
  dogfooding — the shipped capability would later capture-and-remove it.
