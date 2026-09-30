<!-- SPDX-License-Identifier: CC-BY-SA-4.0 -->
<!-- SPDX-FileCopyrightText: Netresearch DTT GmbH -->

# Security assurance case — git-workflow-skill

This document states what a user can expect from this repository in terms of security, and argues why that expectation holds. Every claim names the file that implements it and, where one exists, the test that checks it. Reporting a vulnerability: see the [security policy](https://github.com/netresearch/.github/blob/main/SECURITY.md). Components: [ARCHITECTURE.md](ARCHITECTURE.md).

## What the repository ships

| Part | Files | Runs where |
| --- | --- | --- |
| Skill instructions for an AI agent | `skills/git-workflow/SKILL.md`, `skills/git-workflow/references/*.md`, `commands/pr-finish.md` | Read by the agent as instructions; not executed. The agent may run the git and `gh` commands they describe in the user's repository. |
| Registered hook | `scripts/validate_git_command.py`, registered in `hooks/hooks.json` as a `PreToolUse` hook for the Bash tool | On the user's machine, before each Bash command the agent proposes, when the plugin is installed. |
| Opt-in hooks | `skills/git-workflow/scripts/merge-gate.sh`, `skills/git-workflow/scripts/conflict-marker-gate.py`, `scripts/reference-worktree-gate.py` | Only if the user copies them into their own hook configuration, as `references/claude-code-hooks.md` describes. `hooks/hooks.json` does not register them. |
| Helper scripts | `skills/git-workflow/scripts/pr-status.sh`, `pr-merge.sh`, `signing-preflight.sh`, `repo-contribution-preflight.sh`, `spec-cleanup-guard.sh`, `verify-git-workflow.sh` | When the agent or the user runs them, with the user's git configuration and `gh` authentication. |
| Checkpoints | `skills/git-workflow/checkpoints.yaml` | Only when an assessment tool runs its patterns in a user's project. |
| Repository checks | `Build/Scripts/*`, `Build/hooks/*`, `scripts/verify-harness.sh`, `tests/*`, `scripts/test_*.py` | In this repository's CI and on contributors' machines. |

The repository ships no server component and no container image. It stores no user data. It keeps no credentials of its own: the scripts use the `gh` login and the git configuration the user already has.

## Security requirements

1. The registered hook inspects a proposed command and never executes it.
2. No script passes text from GitHub (pull request titles, bodies, comments, branch names) to a shell for evaluation.
3. `pr-merge.sh` merges only when `pr-status.sh` reports `merge` as the next action, never with `--admin`, and never by squash.
4. The helper scripts do not read, print or store the `gh` token.
5. Scripts that change local state restore it: `signing-preflight.sh` leaves the user's index, branch and staged changes as it found them.
6. Nothing committed to this repository contains a secret, and a release can be verified against the build that produced it.

## Actors and trust boundaries

- **Agent and skill user.** The agent reads the skill as instructions and runs commands in the user's repository with the user's privileges. What the agent then runs is decided by the agent and the user. The registered hook sits on this boundary: it sees the command text before execution and can deny it.
- **GitHub and third parties.** `pr-status.sh` and `pr-merge.sh` read pull request data through `gh`. Titles, bodies, comments, review texts, logins and branch names are written by people outside the user's control and are treated as data.
- **The inspected repository.** `repo-contribution-preflight.sh`, `spec-cleanup-guard.sh` and `verify-git-workflow.sh` read files of the repository they are run in. `signing-preflight.sh` makes a commit there, so that repository's commit hooks run.
- **Contributors.** Changes reach `main` through pull requests, checked by the workflows in `.github/workflows/`.
- **CI.** Workflows run on GitHub-hosted runners with `permissions: {}` at the top level and grant each job only the scopes it needs (`.github/workflows/*.yml`). The two `pull_request_target` workflows (`auto-merge-deps.yml`, `labeler.yml`) call reusable workflows that merge or label; their callers state that those reusables do not check out pull request code.

## Threats and countermeasures

| Threat | Countermeasure | Evidence |
| --- | --- | --- |
| The hook runs the command it inspects, or runs it through a shell (CWE-78) | The hook parses the command text only. Its two subprocesses are fixed argument lists without a shell: `gh api repos/<repo>/commits/<sha>`, where `<repo>` must match `owner/name` characters and `<sha>` is hex, and `git -C <dir> status --porcelain`. Both have a timeout. A `bash -c '…'` payload is unpacked for analysis, not executed. | `scripts/validate_git_command.py` (`_resolve_commit`, the untracked-files check, the `-c` payload handling); `scripts/test_validate_git_command.py`, `scripts/test_promoted_gates.py` |
| GitHub text is evaluated as a command (CWE-78, CWE-94) | No shipped script uses `eval` or a Python subprocess with `shell=True`. `gh` arguments are quoted; GraphQL values are passed as `-f`/`-F` variables; the branch name in a REST path is URL-encoded with `jq @uri`. Commands that `pr-status.sh` suggests are printed, never run. | `skills/git-workflow/scripts/pr-status.sh`, `pr-merge.sh` |
| A merge happens while the gate is shut, bypasses branch protection, or loses history | `pr-merge.sh` merges only when the next action from `pr-status.sh --json` is `merge`, and otherwise exits without writing; the one exception is `--self-reviewed`: on a `request-review` gate whose reason the author may satisfy, it posts the self-review comment (unless one is already on the head), re-reads the gate and exits 1 if the action is still not `merge`. It builds `gh pr merge` as an array with `--merge` or `--rebase` only and refuses a repository that allows only squash; it never adds `--admin`. It drops `--delete-branch` for a merge queue, a fork head and a branch another pull request is based on, and it reads the outcome back instead of trusting the exit code. | `skills/git-workflow/scripts/pr-merge.sh`; `tests/test_pr_merge_verify_outcome.sh` (case 9: gate shut, `gh` never called), `tests/test_pr_merge_fork_delete_branch.sh`, `tests/test_pr_merge_stacked_pr_delete_branch.sh` |
| A merge is attempted with unresolved review threads or a non-clean merge state | The opt-in `merge-gate.sh` denies `gh pr merge` unless the merge state is `CLEAN` and no review thread is unresolved | `skills/git-workflow/scripts/merge-gate.sh`; `tests/test_hook_gates.sh` |
| A commit carries unresolved conflict markers | The opt-in `conflict-marker-gate.py` denies `git commit` while staged content contains markers; it runs `git` with argument lists | `skills/git-workflow/scripts/conflict-marker-gate.py`; `tests/test_hook_gates.sh` |
| A probe changes the user's repository state | `signing-preflight.sh` commits on a temporary branch with a temporary index seeded from `HEAD`, and an `EXIT` trap switches back and deletes the branch and temporary files | `skills/git-workflow/scripts/signing-preflight.sh`; `tests/test_signing_preflight.sh` |
| Temporary files are predictable or left readable | Scripts create temporary files with `mktemp`; the hook's advisory markers are created with `O_CREAT \| O_EXCL` and mode `0600` under a name derived from a sanitised session id | `pr-merge.sh`, `signing-preflight.sh`, `spec-cleanup-guard.sh`, `scripts/validate_git_command.py` |
| A failing step continues with partial state | `pr-status.sh`, `pr-merge.sh`, `signing-preflight.sh` and `repo-contribution-preflight.sh` run with `set -uo pipefail`; `merge-gate.sh`, `spec-cleanup-guard.sh`, `verify-harness.sh` and `check-plugin-version.sh` with `set -euo pipefail`; `verify-git-workflow.sh` with `set -e` | the scripts named |
| A release is tagged with a version that disagrees with `plugin.json` | The pre-push hook (enabled by `.envrc` through `core.hooksPath`) runs `check-plugin-version.sh`, which fails when a semver tag at `HEAD` differs from `.claude-plugin/plugin.json` | `Build/hooks/pre-push`, `Build/Scripts/check-plugin-version.sh` |
| A released archive is tampered with | The release workflow publishes a Cosign-signed `SHA256SUMS.txt` and SLSA build-provenance attestations for the archives | `.github/workflows/release.yml` (calls the skill-repo-skill release reusable) |
| A secret is committed | Betterleaks scans every push to `main` and every pull request to `main` | `.github/workflows/security.yml` |
| A vulnerable or malicious dependency is added | Dependency review fails on vulnerabilities of severity high or above in a pull request; Composer Audit checks the Composer dependencies; Renovate proposes updates | `.github/workflows/security.yml`, `renovate.json` |
| Insecure code or workflow patterns | CodeQL analyses the Python code and the workflows with the `security-extended` queries; Opengrep (`--config auto --error --severity WARNING`) fails on findings of WARNING-level rules only (ERROR-level rules are not reported, netresearch/typo3-ci-workflows#268); zizmor analyses the workflows; ShellCheck runs on every `*.sh` file and ruff on every Python file in Skill Validation | `.github/workflows/codeql.yml`, `.github/workflows/security.yml`, `.github/workflows/lint.yml` |
| A regression in a hook or script goes unnoticed | The shell and Python suites under `tests/` run in Skill Tests, the hook unit tests under `scripts/` in Hook Script Tests, on every pull request | `.github/workflows/tests.yml`, `.github/workflows/hook-tests.yml` |

Which of these checks must pass before a pull request can merge is set in the branch protection of `main`, not in this repository.

## Secure design principles applied

- **Least privilege:** the scripts use the user's existing `gh` login and never ask for more; workflows start from `permissions: {}` and check out code with `persist-credentials: false` (`codeql.yml`, `hook-tests.yml`).
- **Mediation before execution:** each Bash command the agent proposes is handed to `validate_git_command.py` before it runs (`hooks/hooks.json`).
- **Fail-safe for the user's work:** the opt-in gates allow the command when they cannot decide (`reference-worktree-gate.py` and `conflict-marker-gate.py` state this in their headers), so a broken gate does not block work; a gate that refuses on its own failure would push users to disable it.
- **Economy of mechanism:** the scripts need bash, git, `gh`, `jq` and Python's standard library; `spec-cleanup-guard.sh` also needs `yq` when a `.spec-cleanup.yml` exists, and refuses to run without it rather than check less.
- **Separation of reading and acting:** `pr-status.sh` changes nothing on GitHub and prints the next action; `pr-merge.sh` is the one script that merges, and it acts only on that reading.

## What a user cannot expect

- The hooks are guard-rails against mistakes of an agent, not a sandbox. A command built on purpose to get past them can do so. They do not replace reviewing what an agent proposes to run.
- `allowed-tools` in `SKILL.md` (`Bash(git:*) Bash(gh:*) Read Write`) pre-approves those tools while the skill is active. It does not remove other tools the agent has.
- The helper scripts act with the user's `gh` token and git configuration. `pr-merge.sh` merges with the user's rights; the host's branch protection remains the authority on what may merge.
- `signing-preflight.sh` makes a commit in the repository it checks, so that repository's commit hooks run. Run it only in repositories you trust.
- The checkpoints run shell commands in the assessed project when an assessment tool executes them; the LLM review checkpoints are judgements by a model and can miss issues.
- Security fixes follow the supported-versions rules of the organisation's security policy; older releases may not receive them.
