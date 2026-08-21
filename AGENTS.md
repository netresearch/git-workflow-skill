# Git Workflow Skill

Expert patterns for Git version control: branching, commits, collaboration, and CI/CD.

## Repo Structure

```
├── skills/git-workflow/
│   ├── SKILL.md                    # Skill metadata and core patterns
│   ├── checkpoints.yaml            # Skill checkpoints
│   ├── evals/                      # Skill evaluations
│   ├── references/                 # Detailed reference docs (see below)
│   └── scripts/
│       ├── verify-git-workflow.sh  # Git workflow verification
│       └── spec-cleanup-guard.sh   # Read-only gate for intermediate planning artifacts
├── .spec-cleanup.yml.example       # Template config for the spec-cleanup guard
├── Build/
│   ├── Scripts/                    # Build/validation scripts
│   └── hooks/                      # Git hook templates (pre-commit, pre-push)
├── hooks/
│   └── hooks.json                  # Hook configuration
├── scripts/
│   ├── verify-harness.sh           # Harness consistency checker
│   └── validate_git_command.py     # Git command validator
├── .github/workflows/              # CI workflows (lint, release, auto-merge)
├── docs/                           # Architecture and planning docs
├── composer.json                   # Composer package manifest
└── README.md
```

### Doc folder taxonomy (for the spec-cleanup guard)

The spec-cleanup capability (`references/spec-cleanup.md`) distinguishes two
classes of doc folder. The machine-readable source of truth is
`.spec-cleanup.yml` (here, `.spec-cleanup.yml.example` — this repo ships no
active config, so the guard is not wired into its own gate; run manually with the
baked-in defaults it *does* flag the dogfooded design spec, by design).

- **Persisted / durable** — keep in the base branch: `docs/adr/`, `docs/PRD.md`,
  `Documentation/`, plus this repo's `docs/` architecture/planning notes.
- **Intermediate / working** — must never reach the base branch:
  `docs/superpowers/`, `claudedocs/`, `docs/working/`, ad-hoc `*.plan.md`.

## Where a fact has to live for the model to see it

Three surfaces, three different moments. Putting something on the wrong one is
why a capability that exists still does not get used.

| Surface | When it enters context | Budget |
|---|---|---|
| `description` in the frontmatter | always, in the skill listing | combined description text truncated at **1536 characters**; the listing itself is capped at ~1% of the context window |
| `SKILL.md` body | when the skill is invoked | published guidance is **under 500 lines**; the gate here enforces **500 words over the whole file** (see below) |
| `references/*.md` | when the model chooses to read one | none, they cost nothing until read |

What follows from that:

- **A missing capability in the `description` is the only true skip.** The model
  never invokes the skill, so nothing further is consulted. Put the key use case
  first: when many skills are installed the listing overflows its budget and
  descriptions get shortened or dropped, starting with the least-used skills.
- **A missing capability in the body is a blind spot, not a skip.** The skill
  runs, and the model does not know the thing exists.
- **Scripts belong in the body.** They are executed, never loaded, so listing one
  costs a line and buys the only chance the model has of knowing it is there.

### The enforced budget is not the documented one

The `validate-skill` pre-commit hook comes from `netresearch/skill-repo-skill`,
and it counts **500 words over the whole file**, frontmatter included. The
published guidance is *"Keep `SKILL.md` under 500 lines"*. Words are a much
tighter budget than lines, and charging the frontmatter to it means the
`description` -- the one surface that decides whether the skill is used at all
-- competes with the instructions for the same allowance.

The practical consequence is visible in this repository's history: it sat at
499 of 500 and left a script out of `SKILL.md` rather than spend fourteen words
on it. Note also that `Build/Scripts/validate-skill.sh` here is a COPY that
nothing runs -- editing it changes no gate.

Until the upstream check is corrected, budget in words and count the
frontmatter. When the body is tight, move detail into an existing reference and
keep the capability: a reader who cannot see that a script exists will not run
it.

### One level of references, and each one says when to read it

The documented shape is flat: `SKILL.md` is the overview and navigation, with
supporting files beside it, and each one referenced *"so Claude knows what each
file contains and when to load it"*. The `Reference Files` table in `SKILL.md`
is that mechanism -- the `Content Triggers` column is not decoration, it is what
lets the model decide to read a file it cannot see.

So do not nest a second hop. `SKILL.md` -> `references.md` -> `topic.md` puts
the third file behind a door with no sign on it: nothing states what it holds or
when it matters, so the model has to open the middle file on speculation and
then guess again. Split by topic at the FIRST level instead -- `topic-a.md` and
`topic-b.md` both listed in the table, each with its own trigger.

The body stays short because detail moves into references, never because facts
get dropped. If the body is at its limit, that is a signal to move a section
into a reference and add a row to the table -- not to leave a capability
undocumented.

## Commands

No build system scripts defined in composer.json. Basic operations:

- `bash skills/git-workflow/scripts/verify-git-workflow.sh` -- verify git workflow setup
- `bash scripts/verify-harness.sh --status` -- check harness maturity level
- `python3 scripts/validate_git_command.py` -- validate git commands

## Rules

- Use Conventional Commits format: `<type>[scope]: <description>`
- Types: `feat`, `fix`, `docs`, `style`, `refactor`, `perf`, `test`, `build`, `ci`, `chore`, `revert`
- Breaking changes: append `!` after type or add `BREAKING CHANGE:` footer
- Prefer atomic commits (one logical change per commit)
- Use signed commits (`-S --signoff`)
- PR merges require: resolved threads, passing CI, rebased branch
- Load reference files based on content triggers (see SKILL.md)

## References

- [SKILL.md](skills/git-workflow/SKILL.md) -- core skill definition and triggers
- [Commit Conventions](skills/git-workflow/references/commit-conventions.md)
- [Pull Request Workflow](skills/git-workflow/references/pull-request-workflow.md)
- [CI/CD Integration](skills/git-workflow/references/ci-cd-integration.md)
- [Advanced Git](skills/git-workflow/references/advanced-git.md)
- [GitHub Releases](skills/git-workflow/references/github-releases.md)
- [Code Quality Tools](skills/git-workflow/references/code-quality-tools.md)
- [Architecture](docs/ARCHITECTURE.md)
