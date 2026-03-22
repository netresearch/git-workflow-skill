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
│       └── verify-git-workflow.sh  # Git workflow verification
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
- [Branching Strategies](skills/git-workflow/references/branching-strategies.md)
- [Commit Conventions](skills/git-workflow/references/commit-conventions.md)
- [Pull Request Workflow](skills/git-workflow/references/pull-request-workflow.md)
- [CI/CD Integration](skills/git-workflow/references/ci-cd-integration.md)
- [Advanced Git](skills/git-workflow/references/advanced-git.md)
- [GitHub Releases](skills/git-workflow/references/github-releases.md)
- [Code Quality Tools](skills/git-workflow/references/code-quality-tools.md)
- [Architecture](docs/ARCHITECTURE.md)
