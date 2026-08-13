# Commit Conventions

## Conventional Commits

### Specification

```
<type>[optional scope]: <description>

[optional body]

[optional footer(s)]
```

### Commit Types

| Type | Description | Version Bump |
|------|-------------|--------------|
| `feat` | New feature | MINOR |
| `fix` | Bug fix | PATCH |
| `docs` | Documentation only | - |
| `style` | Code style (formatting) | - |
| `refactor` | Code refactoring | - |
| `perf` | Performance improvement | PATCH |
| `test` | Adding/updating tests | - |
| `build` | Build system changes | - |
| `ci` | CI configuration | - |
| `chore` | Maintenance tasks | - |
| `revert` | Reverting changes | - |

### Examples

```bash
# Simple feature
feat: add user authentication

# Feature with scope
feat(auth): add OAuth2 login support

# Bug fix
fix: resolve null pointer in user service

# Bug fix with issue reference
fix(api): handle empty response from external service

Fixes #123

# Breaking change
feat!: remove deprecated v1 API endpoints

BREAKING CHANGE: The /api/v1/* endpoints have been removed.
Migrate to /api/v2/* before upgrading.

# Multiple footers
fix(security): patch XSS vulnerability in comment parser

Reviewed-by: John Doe
Refs: #456
```

### Scope Guidelines

Scopes should be consistent across the project:

```bash
# By feature area
feat(auth): ...
feat(payment): ...
feat(notification): ...

# By layer
fix(api): ...
fix(db): ...
fix(ui): ...

# By component
style(button): ...
refactor(modal): ...
```

## Commit Message Best Practices

### Body

**Write multi-line or special-char bodies to a file, not inline `-m`.** The shell parses a double-quoted `-m "..."` before git sees it: an *unescaped* `"` in the body closes the string early, after which a bare `&` backgrounds the fragment and the message silently truncates (a tell-tale `... command not found` may scroll past). Even with the quotes balanced, the shell still expands `$var`, `` `cmd` ``/`$(...)`, and backslashes inside double quotes, so a body containing those is altered. A file or a *single-quoted* heredoc (`<<'EOF'`) sidesteps all of it — the text is passed verbatim:

```bash
git commit -S --signoff -F - <<'EOF'
fix: prevent race condition in order processing

Body may contain "quotes", & ampersands, `backticks` — all literal.
EOF
```

**Hard-wrap the commit *body* (~72 cols); don't hard-wrap prose whose wrapping
you don't control.** The 72-column convention is for commit message bodies —
which is exactly why a commit body must not be piped into a PR description
unchanged; see *The rule breaks at the pipe* in `no-editorializing.md`. For
**PR/MR & issue descriptions, release notes, review comments, and chat**, write
one line per paragraph (and per list item) and let the renderer soft-wrap — a
hard break mid-paragraph there does nothing for the output. For **committed
Markdown files**, follow the repo's existing convention: many hard-wrap prose
docs for readable diffs, so match the surrounding files rather than mixing two
styles in one tree.

## Signed Commits + DCO Sign-Off (Required)

Run every commit with both flags explicit:

```bash
git commit -S --signoff -m "feat: add login endpoint"
```

**Why explicit `-S`.** Git honors `commit.gpgsign=true` only when the configuration is actually loaded. Subprocess environments (CI runners, some IDEs, tools that set their own `$HOME` or scrub env) can miss the global config — and without the config, git doesn't even *try* to sign. Git records the commit as unsigned with no error, because from its perspective signing was never requested. Explicit `-S` pins the requirement to the invocation: now git *always* attempts to sign, and if the signing agent (gpg-agent, or ssh-agent when using `gpg.format=ssh`) or its pinentry prompt is unreachable, the commit aborts noisily. You find out now, not when branch protection rejects the push later.

**Why `--signoff`.** Adds the `Signed-off-by:` trailer. Required for DCO compliance on any repo that has the DCO check enabled (most netresearch repos do).

**Sign-off identity must match `git config user.{name,email}`.** Mismatched identities fail the DCO check with an unhelpful "signoff required" error. Validate before the first commit in a new worktree — and specifically check that the values are not swapped (an email address in `user.name` is a silent misconfiguration that produces a malformed `Signed-off-by:` trailer):

```bash
git config user.name   # must look like "Firstname Lastname", NOT an email address
git config user.email  # must contain "@", NOT a plain name

# Fix if swapped:
git config --global user.name "Firstname Lastname"
git config --global user.email "you@example.com"
```

**Commit locally to satisfy verified-signature branch protection — not via the host's Contents API.** Commits created through the GitHub Contents API (`PUT /repos/.../contents/...`), or any host-side write that supplies its own `committer`/`author`, come out **unsigned** (`verification.verified=false`, `reason: unsigned`) — the host does not web-flow-sign them. A repo that enforces verified signatures rejects the merge, and when admin enforcement is on you cannot bypass it. So when scripting commits across many repos, check the signature requirement up front alongside required checks and reviews:

```bash
gh api repos/"$R"/branches/main/protection \
  --jq '.required_signatures?.enabled? // false'   # $R="owner/repo"; also inspect rulesets
```

For any repo that enforces signatures, create the commit **locally** with signing configured (`git commit -S --signoff`) rather than through the API — a locally SSH/GPG-signed commit verifies on the host, an API-authored one does not.

**SSH signing keys on GitHub: auth keys ≠ signing keys.** An SSH key registered under *Settings → SSH and GPG keys → Authentication Key* cannot verify commits. It must also be added as a *Signing Key* (same page, different Key type dropdown). GitHub reports unsigned-with-known-key commits as `reason: unknown_key` in the commits API — identical to an unregistered key. Check before the first push to a repo with verified-signature branch protection:

```bash
# Verify the key is registered as a signing key (requires admin:ssh_signing_key token scope):
gh auth refresh -h github.com -s admin:ssh_signing_key
gh api /user/ssh_signing_keys --jq '.[].key'

# Or check commit verification after pushing one commit:
gh api /repos/{owner}/{repo}/commits/HEAD --jq '.commit.verification | {verified, reason}'
# "reason":"valid"        → OK
# "reason":"unknown_key"  → key not registered as signing key
# "reason":"unsigned"     → -S flag not used or signing config missing
```

**Trust the inherited ssh-agent; don't hunt for sockets.** When commits are SSH-signed through a running ssh-agent, the `SSH_AUTH_SOCK` already present in the inherited shell environment normally holds the signing key and works transparently. Do **not** reflexively export a hardcoded `SSH_AUTH_SOCK` or probe the filesystem for agent sockets — a stale or wrong socket path overrides the working inherited one and breaks signing that would otherwise have succeeded. If signing actually fails (`failed to write commit object`, `error: gpg failed to sign the data`, or a `publickey` error), stop and surface the error to the operator rather than autonomously searching for the "right" socket.

**A signing key dropped from the agent mid-session breaks signing *and* SSH git at once.** If the agent had the key earlier but `ssh-add -l` now prints `The agent has no identities.` (a passphrase-protected key can time out or be evicted), then `git commit -S` aborts (`ssh_askpass: … No such file`, "incorrect passphrase", `failed to write commit object`) **and** `git fetch`/`git push` over an SSH remote fail with `Permission denied (publickey)`. The push half has a fallback — route it over HTTPS with the `gh` token (`gh auth setup-git`, then `git push https://github.com/owner/repo.git <branch>`) — but **signing has no such fallback**: the SSH key file must be re-added. Do not bypass signing to get unblocked; ask the operator to re-add it (`ssh-add <signing-key>`, e.g. `~/.ssh/id_ed25519`, which prompts for the passphrase). Both signing and SSH git recover once it is loaded.

**Never amend a commit with pre-commit-hook failures.** If the pre-commit hook fails, the commit **did not happen**. Running `git commit --amend` then modifies the PREVIOUS commit, which can destroy work. Fix the hook issue, re-stage, and create a new commit.

**Prove the commit landed before reporting it — compare HEAD, not the last commit.** A reformatting hook (`ruff format`, `black`, `isort`, `prettier`) rewrites the staged files and *aborts* the commit. Every check that reads "the last commit" then describes the commit before yours and reports success:

```bash
BEFORE=$(git rev-parse HEAD)
git add -- path/to/file path/to/other
git commit -s -F msg.txt
[ "$(git rev-parse HEAD)" != "$BEFORE" ] || { echo "commit aborted — re-stage and retry" >&2; exit 1; }
git log -1 --format='%h %s'           # now describes YOUR commit
```

Checking `git commit`'s own exit code works, but only if nothing reads it first — and in practice the next thing in the block is a status line that answers from the *previous* commit and looks right. `git log -1 --format='%G?'` prints the same value it printed before the aborted commit, and the `git push` that follows succeeds while pushing nothing new, because the branch never moved. HEAD is the one value the aborted commit did not leave intact, which is why comparing it answers the question the others only appear to.

**Never skip hooks** unless explicitly told to. `--no-verify` bypasses hook enforcement that exists for good reasons. If a hook fails, diagnose the root cause. The one exception is a throwaway *probe* commit that is deleted moments later and never enters history — `signing-preflight.sh` retries with `--no-verify` there, and only to tell a hook rejection apart from a signing failure.

**Never bypass signing** unless explicitly told to. `--no-gpg-sign` and `-c commit.gpgsign=false` disable commit signing; the result will fail branch-protection or policy checks that require signed commits later.

**Verify signing capability without committing on `main`.** To check that signing
actually works (right key, agent reachable), do **not** create a probe commit on the
default branch — even an immediately-reset `git commit --allow-empty -S` on `main` is a
transient commit on a protected branch and violates "no direct commits to main". Inspect
configuration instead, no commit required:

```bash
git config commit.gpgsign     # expect: true
git config gpg.format         # ssh (SSH signing) or empty (GPG)
git config user.signingkey    # the key/path that will be used
```

If you must actually exercise the signing path, run `scripts/signing-preflight.sh`
— it does the whole dance below and cleans up after itself. By hand, do it on a
throwaway branch and discard it:

```bash
git switch -c tmp/sign-probe
# conventional msg so a commit-msg hook won't reject it; header, not %G? — see "Detecting a Signed Commit" below
git commit --allow-empty -S -m "chore: signing probe" \
  && (git cat-file commit HEAD | sed -n '/^$/q;p' | grep -qE '^gpgsig(-sha256)? ' && echo signed || echo "NOT signed") \
  || echo "NOT signed — commit failed"   # keep the chain: unchained, the check reads the parent commit
git switch - && git branch -D tmp/sign-probe
```

### Verifying a Signed Tag

A tag needs two properties, and they fail independently:

```bash
git for-each-ref refs/tags/v1.2.3 --format='%(objecttype)'   # expect: tag, not commit
git tag -v v1.2.3
```

`objecttype: commit` means a **lightweight** tag — created without `-a`/`-s`,
carrying no signature and no tagger. Many release pipelines reject these
outright, and `git tag -v` on one reports an error that reads like a bad
signature rather than a missing one.

**Do not grep for `Good signature`.** The wording depends on the signing
backend, and an SSH-signed tag does not use that phrase:

| Backend | Output |
|---|---|
| GPG | `Good signature from "Name <mail>"` |
| SSH (`gpg.format=ssh`) | `Good "git" signature for mail with ED25519 key SHA256:…` |

With `gpg.format=ssh` set — increasingly the default in this org — a check for
`Good signature` returns nothing and a correctly signed tag looks unsigned.
Match on both, or on the object type plus a looser pattern:

```bash
git tag -v v1.2.3 2>&1 | grep -qE 'Good ("git" )?signature' && echo signed
```

`git tag -v` needs `gpg.ssh.allowedSignersFile` as well. Without it, it prints
`error: gpg.ssh.allowedSignersFile needs to be configured and exist for SSH
signature verification`, exits 1, and the pattern above matches nothing (git
2.54.0) — so a failed match means "not verifiable *here*", not "unsigned".

### Detecting a Signed Commit

Signedness and verification are different questions, and only the first has a
stable local answer: whether a commit *carries* a signature is a property of the
object, whether *this machine* trusts that signature depends on local config.
The check below answers the first one only.

For that question, do not reach for `git log --format='%G?'`: it is
backend-independent but *not* verification-config-independent. Under
`gpg.format=ssh` with no `gpg.ssh.allowedSignersFile`, `%G?` returns `N` and
`--show-signature` prints `No signature` on a correctly signed commit (git
2.54.0) — `N` is indistinguishable from unsigned, and setting that config flips
the identical commit to `G`. Read the commit header instead, which both backends
write (`-----BEGIN SSH SIGNATURE-----` / `-----BEGIN PGP SIGNATURE-----`) and no
local config gates:

```bash
scripts/signing-preflight.sh --check-commit HEAD      # exit 0 signed, 1 unsigned
# by hand:
git cat-file commit HEAD | sed -n '/^$/q;p' | grep -qE '^gpgsig(-sha256)? ' && echo signed
```

`gpgsig-sha256` is the header name in SHA-256 repositories; the alternation
covers both. Match the header name and the space, so nothing else in the header
block can pass.

Cut the header at the first blank line — over the whole object, `^gpgsig` also
matches a message body line starting with `gpgsig` and reports an unsigned commit
as signed. Whether the *host* accepts the key is a separate question, answered
only by the commits API check above.

## Atomic Commits

Each commit should be a **single, self-contained logical change** that builds and passes tests independently.

**Good:**

- `feat: add user authentication endpoint` (one feature, complete)
- `fix: correct SAML attribute name mapping` (one bug, fixed)
- `chore(deps): bump go-ldap/ldap/v3 from 3.4.8 to 3.4.11` (one bump)

**Bad:**

- `feat: add auth + fix typo + update deps` (three unrelated concerns)
- `wip` / `fixup` (leftover scratch commits)

Rewrite messy history before opening the PR:

```bash
git rebase -i main        # interactive, squash / reword / reorder
git rebase -i --autosquash main   # auto-pick fixup!/squash! commits
```

## Push Upstream on First Push

When pushing a new branch for the first time, set upstream tracking with `-u`:

```bash
git push -u origin feature-branch
```

This makes subsequent `git pull` / `git push` work without specifying remote+branch. Without `-u`, everyone who clones the branch later has to set it up themselves.
