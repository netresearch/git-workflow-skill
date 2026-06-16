# Spec-Cleanup Capability — Design

- **Date:** 2026-06-16
- **Status:** Draft (revised after adversarial review; pending implementation plan)
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

Two distinct needs with different failure modes were conflated in the chat:

- **Hygiene / gate** — keep throwaway planning files out of the base branch.
  Deterministic, mechanical, read-only, safe to enforce in CI.
- **Knowledge capture** — distil durable decisions into ADR/PRD/user docs before
  the raw files are removed. Creative, judgment-heavy, must stay human-reviewed.

Bundling them into one silent "convert + remove on merge" does both badly: a
poor auto-summary becomes a false source of truth, or a skipped capture blocks
the merge. The design keeps them as two layers in one capability, and removal is
always recoverable (it goes through git history, never bare `rm`).

## 2. Goals / Non-Goals

### Goals

- Block the base branch from receiving tracked intermediate artifacts.
- Detect artifacts in **all three states**: committed/tracked, staged, and
  untracked working-tree files.
- Make every removal **recoverable** — go through git, never destroy untracked
  content with bare `rm`.
- Propose (never silent-write) durable docs from the artifacts, for human review.
- Be a no-op when a branch has no intermediate artifacts (no cosmetic gate).
- Ship usable defaults; let repos extend via `.spec-cleanup.yml`; declare the
  folder taxonomy in `AGENTS.md`.

### Non-Goals

- Auto-discovering "every intermediate file everywhere" by heuristic. Enforced
  detection is anchored to declared globs (§3.2). Session context is used only to
  *discover and register* stray artifacts (§3.4), never as a silent deletion
  driver.
- Auto-writing documentation without review.
- Replacing the existing merge gate or `oro-qa-reviewer`; this composes with them.
- A standalone skill — this lives inside `git-workflow-skill`.

## 3. Architecture

Two layers, one capability, wired into the existing `/pr-finish` flow and merge
gate:

```
/pr-finish  (new step 0.5, before Rebase — branch must be clean before the gate)
  └─ Guard (deterministic, READ-ONLY): tracked|staged|untracked intermediate artifacts?
        ├─ none → existing Rebase → Merge Gate → Merge
        └─ some → Capture (in-session)
                    → print deletion manifest (grouped by state)  ── confirm ──┐
                    → convert: propose ADR diff → human accepts → commit docs    │
                    → verify docs commit landed                                  │
                    → stage any untracked raw → commit removal (recoverable)     │
                    → Guard re-check → clean → Rebase → Merge Gate → Merge ──────┘
```

### 3.1 Guard — deterministic, read-only (the enforceable net)

`skills/git-workflow/scripts/spec-cleanup-guard.sh` (skill-scoped, alongside
`verify-git-workflow.sh`; `set -euo pipefail` per repo convention). Context-free
so it runs at the merge gate and in CI with no session.

**Invariant: the Guard NEVER deletes, stages, or modifies any file.** It reports
and exits non-zero. Only the interactive Capture step removes files (§3.5).

It is **branch-local and state-based**: it flags the *presence* of intermediate
artifacts in the current working tree / index, independent of any base branch
(intermediate paths must never be tracked anywhere, so presence ⇒ fail; this
sidesteps base-branch resolution entirely). The three states:

| State | Detection (exact) |
|-------|-------------------|
| committed/tracked | `git ls-files -- <pathspecs>` |
| staged | `git diff --cached --name-only --diff-filter=AM -- <pathspecs>` |
| untracked working-tree | `git ls-files --others --exclude-standard -- <pathspecs>` |

**Pathspec mechanism (pinned).** Git pathspec globbing is NOT shell/gitignore
globbing. The Guard normalizes each config glob to a git pathspec:
- a directory glob (`docs/superpowers/**`, `claudedocs/**`) → a **directory
  pathspec** (`docs/superpowers/`, `claudedocs/`), which matches all files
  beneath it recursively;
- a suffix glob (`docs/superpowers/**/*.plan.md`) → **`:(glob)` magic**
  (`:(glob)docs/superpowers/**/*.plan.md`), where `**` is explicitly recursive.

`exclude:` globs are applied as negative pathspecs / post-filter. A `--selftest`
asserts a nested file `docs/superpowers/a/b/c.md` is caught in all three states.

`--dry-run`/default output lists every match grouped by state. On matches it
exits non-zero with the three resolutions (convert / remove / acknowledge).

**Config parsing.** Defaults (§3.3) are baked into the script. If
`.spec-cleanup.yml` exists it is parsed with `yq`. If the config exists but `yq`
is absent, the Guard **fails closed** with a clear error (it must not silently
fall back to defaults and under-enforce). `yq` is declared in SKILL.md
compatibility as required-when-a-config-is-present.

### 3.2 Wiring (read-only enforcement points)

- **Merge gate** — add a Guard checklist item + command recipe to the Merge Gate
  section of `references/pull-request-workflow.md` (mirroring the existing
  annotations check). The merge gate is prose + recipes, not an executable
  pipeline; the recipe runs `spec-cleanup-guard.sh` and blocks on non-zero.
- **Optional runtime block** — for repos wanting earlier enforcement, a recipe in
  `references/claude-code-hooks.md` extends the documented `merge-gate.sh` Claude
  Code **PreToolUse** hook to also run the guard. A **git** `pre-commit` template
  (distinct system) can be added under `Build/hooks/` calling the guard; **off by
  default** (initial commit of working notes is allowed — Paul's point). The spec
  never says "pre-commit hook in `hooks/`": `hooks/hooks.json` is Claude-hook
  config; git-hook templates live in `Build/hooks/`.

### 3.3 Config — `.spec-cleanup.yml`

Single source of truth for paths. Built-in defaults ship in the guard, so a repo
with no config still guards `docs/superpowers/**`.

```yaml
intermediate_paths:               # throwaway planning artifacts (Guard + Capture)
  - docs/superpowers/**
  - claudedocs/**
  - docs/working/**
  - docs/superpowers/**/*.plan.md  # anchored — NOT a bare **/*.plan.md
exclude:                          # never treat these as intermediate
  - docs/superpowers/specs/**/KEEP-*.md
capture_targets:
  adr: docs/adr/                  # v1 target (append new file)
  # prd:  docs/PRD.md             # deferred to phase 2 (update-in-place)
  # docs: Documentation/          # deferred to phase 2 (user-doc stubs)
mode: convert                     # convert | remove   (default: convert)
```

- Default `intermediate_paths` are **path-anchored**; the bare `**/*.plan.md`
  pattern is forbidden (it would match arbitrary project files).
- `exclude:` lets a repo keep a deliberate artifact that matches a glob.
- `mode`: **`convert`** (default) or **`remove`**. There is no `block` mode — the
  Guard's hard block already covers "just block."

### 3.4 Detection sources — enforcement vs discovery

- **Enforced detection** (Guard *and* Capture deletion set) = declared globs
  only. This is the single, deterministic deletion driver.
- **Discovery** (Capture, in-session only) = the agent additionally surfaces
  **session-known artifact paths** it authored this session that match no glob
  (ad-hoc `PLAN.md`, other-tool output). These are **not** silently deleted;
  Capture proposes **adding them to `.spec-cleanup.yml`** (or committing them
  under a globbed path) so the deterministic Guard — including CI, which cannot
  see session state — catches them thereafter. This closes the "CI can't see
  session paths" gap by funnelling discovery back into the enforced globs.

### 3.5 Capture — assisted, proposes only, recoverable removal

A `/pr-finish` step (in-session). Sequence:

1. **Manifest + confirm.** Print every match grouped by tracked/staged/untracked.
   Require explicit human confirmation. The untracked subset is called out
   separately because it is the only irrecoverable-by-default class.
2. **Convert (default).** A sub-agent reads the artifacts and **proposes an ADR
   diff** into `capture_targets.adr` (v1). Routing heuristic: *decisions with
   alternatives considered → ADR* (v1's only target). Phase 2 adds *requirement/
   scope changes → PRD update* and *end-user-facing behavior → user doc*. Human
   reviews the diff; on accept the docs are committed.
3. **Verify capture landed.** Before any removal, assert the docs commit exists
   and contains the intended paths (`git show --stat HEAD`) and the tree no longer
   reports them uncommitted. On any failure (blocked hook, signing failure, empty
   diff) **abort removal** and surface the error.
4. **Recoverable removal.** Stage any untracked raw artifacts so they enter
   history, then commit their deletion as `chore: remove working specs/plans
   (captured in <ADR>)`. Because the team never squashes (repo rule), the raw
   content remains recoverable from branch/merge history. **Bare `rm` of untracked
   content is forbidden** — every removal is a git deletion of a tracked file.
5. **Acknowledge path.** If the human asserts nothing durable (or `mode: remove`),
   skip step 2; still do steps 1, 3-trivially, 4, and record a
   `Spec-Cleanup: acknowledged` trailer **on the removal commit**, body listing
   the removed paths. The acknowledging actor is whoever runs `/pr-finish`; the
   acknowledgement covers all artifacts at the gate regardless of original author;
   the trailer commit is signed/DCO-compliant by that actor.

**Mode precedence.** `mode` is the default offered; a human may always escalate to
a stricter outcome (decline conversion → remove) but the tooling never silently
loosens. `mode: remove` still requires the manifest+confirm of step 1 and the
recoverable-removal of step 4.

### 3.6 AGENTS.md — folder taxonomy declaration (human source of truth)

`AGENTS.md` "Repo Structure" gains a subsection distinguishing **persisted/
durable** doc folders from **intermediate/working** folders:

```
docs/adr/, docs/PRD.md, Documentation/          # persisted — durable knowledge
docs/superpowers/, claudedocs/, docs/working/   # intermediate — never reach base
```

This is human-facing documentation. `.spec-cleanup.yml` remains the single
machine-readable source the Guard reads. **No automated AGENTS.md↔config
consistency/drift check in v1** — it duplicates a source to then police it;
deferred until the two are shown to drift in practice.

## 4. Resolution paths

The gate is clean only when **no** intermediate artifact remains in **any** of the
three states.

1. **Convert** (default) — manifest+confirm → propose ADR → human accepts →
   docs committed → verify → recoverable removal.
2. **Remove** — manifest+confirm → recoverable removal (no conversion); used for
   `mode: remove` or when the human declines conversion.
3. **Acknowledge** — manifest+confirm → recoverable removal + trailer; the human
   asserts nothing durable.

Idempotency: Capture operates only on artifacts still present in one of the three
states; already-removed/session paths are dropped; a re-run on a clean branch is a
Guard no-op. ADR proposal must detect already-applied content (no duplicate ADR).

## 5. Error handling / edge cases

- **No config** → baked-in defaults (`docs/superpowers/**`), `convert`, `adr`
  target absent → degrades to remove-with-acknowledgement.
- **`yq` absent but config present** → Guard fails closed (does not under-enforce).
- **Capture low-confidence / empty extraction** → no auto-write; surfaces
  "nothing durable found, confirm removal."
- **Capture target dir missing** (`docs/adr/` absent) → create it and seed ADR
  numbering at `0001`; ADR ids use `NNNN-slug` derived from the next free number,
  collisions on parallel branches resolved at rebase (renumber the later one).
- **Reference project / empty `src/`** → no intermediate files → Guard no-op
  (avoids the "cosmetic stage" smell raised in the same chat).
- **Binary / very large plans** → Guard only checks path presence; Capture reads
  text and skips binaries.
- **CI context (no session)** → only the Guard runs; it enforces the configured
  globs. Session-only ad-hoc paths are caught only after §3.4 registers them in
  config — this residual gap is explicit, not silent.
- **Already-clean branch** → Guard no-op, merge proceeds normally.

## 6. Scope

**v1 (this PR's implementation plan):**
- `spec-cleanup-guard.sh` (read-only, three-state, pinned pathspecs, `--selftest`,
  `--dry-run`, fail-closed config).
- `.spec-cleanup.yml` schema + baked defaults + `exclude:`.
- Merge-gate checklist item + recipe in `pull-request-workflow.md`.
- Capture step in `/pr-finish`: manifest+confirm, **ADR-only** conversion,
  verify-before-remove, recoverable removal, acknowledge trailer.
- Tests per §7.

**Deferred (follow-ups):** PRD update-in-place and user-doc capture targets;
the off-by-default git `pre-commit` template and PreToolUse runtime block;
session-known-path *auto-registration* UX polish; `block` mode (only if a
concrete need surfaces); any AGENTS.md↔config drift check.

## 7. Testing (matched to each layer's real harness)

- **Guard shell self-test** — `skills/git-workflow/scripts/spec-cleanup-guard.sh
  --selftest` (sibling-style to `verify-git-workflow.sh`), sets up git fixtures
  and asserts exit codes:
  - T1 tracked `docs/superpowers/**` present → non-zero, listed under tracked.
  - T2 untracked intermediate file → non-zero, listed under untracked.
  - T3 nested `docs/superpowers/a/b/c.md` → caught in all three states (pathspec).
  - T4 no config → default guard active on `docs/superpowers/**`.
  - T5 `exclude:` match → not flagged.
  - T6 clean branch → exit 0 (no-op).
  - T7 config present, `yq` simulated-absent → fail-closed non-zero.
- **Agent-behavior evals** (`skills/git-workflow/evals/evals.json`, prompt +
  content/tool_use assertions): agent invokes the Guard at `/pr-finish`; agent
  proposes an ADR rather than committing raw specs to base.
- **Checkpoint** (`skills/git-workflow/checkpoints.yaml`, repo-state): a
  `contains`/`file_exists` check that an assessed repo declares intermediate
  paths (`.spec-cleanup.yml` or the AGENTS.md layout subsection).

## 8. Delivery

- Feature PR on `git-workflow-skill` (`feature/spec-cleanup-capability`).
- No version bump / CHANGELOG entry in the feature PR (separate release flow).
- Signed commits (`git commit -s`); DCO-enforced repo.
- The `ecom-orocommerce-docker` repo adopts the capability via its own
  `.spec-cleanup.yml` (orocommerce globs + ADR target); no forked logic; composes
  with the existing `oro-qa-reviewer` agent.
- This design doc lives under `docs/superpowers/specs/` as intentional
  dogfooding — the shipped capability would later capture-and-remove it.

## Appendix — review provenance

Revised against a 6-dimension adversarial review (2026-06-16): blockers fixed
(untracked-`rm` irreversibility → recoverable git removal; glob over-match → anchored
defaults + `exclude:`; `hooks/` vs `Build/hooks/` conflation). High/medium fixes:
pinned git pathspec mechanism, `yq` fail-closed, verify-before-remove, dry-run
manifest, read-only Guard invariant, skill-scoped script location, merge-gate
recipe wiring, `/pr-finish` insertion point, tests split across self-test/evals/
checkpoint. Scope cuts (confirmed findings): dropped `block` mode, AGENTS.md↔config
drift check, and session-introspection-as-deletion-driver; sequenced ADR-first with
PRD/user-doc deferred.
