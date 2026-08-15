# Claude Code Hooks for Workflow Enforcement

Ready-to-drop `settings.json` hook recipes that enforce the critical rules from `SKILL.md` at tool-invocation time. These run in the Claude Code harness, not in git — they catch violations before the command executes.

For git-side hooks (pre-commit, pre-push), see `references/git-hooks-setup.md` instead.

## Where to put these

| Scope | File | When to use |
|-------|------|-------------|
| Personal, all projects | `~/.claude/settings.json` | Enforce your own rules everywhere |
| Team, committed to repo | `.claude/settings.json` | Enforce team rules for this project |
| Personal, one project | `.claude/settings.local.json` | Overrides for this project only |

Merge carefully — read the existing `hooks:` block, add to arrays, never replace wholesale.

## Recipe 1: Block `gh pr merge` When Review Threads Are Open

Blocks any `gh pr merge` invocation that would merge a PR with unresolved review threads or a non-CLEAN merge state.

The merge-gate logic is non-trivial, so it ships as an external script — `scripts/merge-gate.sh` in this skill — rather than inline JSON. Install it and reference it:

```bash
cp <skill>/scripts/merge-gate.sh ~/.claude/hooks/merge-gate.sh
chmod +x ~/.claude/hooks/merge-gate.sh
```

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "if": "Bash(gh pr merge *)",
            "command": "~/.claude/hooks/merge-gate.sh"
          }
        ]
      }
    ]
  }
}
```


The hook denies `gh pr merge` when review threads are unresolved or `mergeStateStatus != CLEAN` (`UNSTABLE` — a non-required check red — is still a deny). It deliberately does not gate on `reviewDecision`: repos without a required-approval rule report `""` and merge legitimately when CLEAN. It parses the three PR-reference forms `gh pr merge` accepts (plain number — with long/short and `=`-joined flags before it — full URL, `owner/repo#N`), paginates the thread list, and honors an explicit `--repo`/`-R` flag — without that, the PR number resolves against the CWD repo and produces false denials when the command targets another repo. If parsing or the PR lookup fails, the hook allows the call rather than producing false-positive denies. Two usage caveats: the hook evaluates at Bash-call time, so never chain a wait-until-CLEAN loop and the merge in one invocation (wait in one call, merge in the next); and it is a personal-harness gate — server-side branch protection remains the authoritative enforcement.

## Recipe 2: Reject Edits to Installed Cache Paths

Prevents `Write` / `Edit` / `MultiEdit` from targeting `~/.claude/skills/...`, `~/.claude/plugins/cache/...`, or any `.bare/` path — which would be silently clobbered on the next update.

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Write|Edit|MultiEdit",
        "hooks": [
          {
            "type": "command",
            "command": "jq -r '.tool_input.file_path // \"\"' | { read -r P; case \"$P\" in */.claude/skills/*|*/.claude/plugins/cache/*|*/.claude/plugins/marketplaces/*|*/.bare/*) echo \"{\\\"hookSpecificOutput\\\":{\\\"hookEventName\\\":\\\"PreToolUse\\\",\\\"permissionDecision\\\":\\\"deny\\\",\\\"permissionDecisionReason\\\":\\\"cache path rejected: $P — edit the source worktree instead\\\"}}\";; esac; }"
          }
        ]
      }
    ]
  }
}
```

## Recipe 3: Warn on Unauthorized Squash

Does not block — just emits a warning. Squash is legitimate on repos with a squash policy; full blocking would be too noisy. The warning is enough to prompt the user to confirm intent.

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "if": "Bash(gh pr merge *)",
            "command": "jq -r '.tool_input.command' | grep -qE -- '--squash\\b' && echo '{\"systemMessage\":\"⚠ squash merge requested — confirm the repo uses squash policy; default is atomic commits\"}' || true"
          }
        ]
      }
    ]
  }
}
```

## Recipe 4: Auto-Lint Go Files After Write/Edit

Runs `golangci-lint` on the file's directory after any write. Silent-success; logs only on failure.

```json
{
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "Write|Edit|MultiEdit",
        "hooks": [
          {
            "type": "command",
            "command": "jq -r '.tool_input.file_path // .tool_response.filePath // \"\"' | { read -r F; [ -z \"$F\" ] && exit 0; case \"$F\" in *.go) cd \"$(dirname \"$F\")\" && golangci-lint run --fast 2>&1 | head -40 || true;; esac; } 2>/dev/null"
          }
        ]
      }
    ]
  }
}
```

Swap `golangci-lint` for your project's linter of choice. For PHP: `vendor/bin/php-cs-fixer fix --dry-run -- "$F"`. For JS/TS: `bunx eslint "$F"`.

## Recipe 5: Sentinel on "Verified" Claims Without Tool Output

Experimental — uses a `prompt` hook to audit assistant messages declaring pass/verified. Only runs on Stop events (end of assistant turn).

```json
{
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "prompt",
            "prompt": "Check the just-ended assistant turn. If it contains any of: 'verified', 'tested', 'all green', 'tests pass', 'should work now', 'try again' — AND no Bash/Read tool result in the same turn shows actual command output substantiating the claim — emit a systemMessage warning. Otherwise stay silent.\n\n$ARGUMENTS"
          }
        ]
      }
    ]
  }
}
```

This is a soft guardrail — the hook can't block a past message, only flag it to the user. Useful as a "you said tested but didn't run anything" reminder.

## Deploying Hooks

After editing `settings.json`:

```bash
# Validate JSON syntax first — broken JSON silently disables ALL settings
jq -e '.hooks' .claude/settings.json

# Reload config — open and close the /hooks menu in Claude Code, or restart
```

The settings watcher only picks up new hook files if `.claude/` existed at session start. If you created `.claude/settings.json` during a session, open `/hooks` once to reload.

## Recipe 6: Block `git commit` While Staged Content Has Conflict Markers

A resolver that exits non-zero does **not** stop a following `git add -A && git commit` in the same Bash call — the `&&` chain starts fresh after the failed command, so the commit lands with `<<<<<<<` in the tree and nothing reports it until a later gate run. `verify-git-workflow.sh` finds markers on demand; this denies the commit that would create them.

```bash
cp <skill>/scripts/conflict-marker-gate.py ~/.claude/hooks/
chmod +x ~/.claude/hooks/conflict-marker-gate.py
```

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          { "type": "command", "command": "python3 $HOME/.claude/hooks/conflict-marker-gate.py" }
        ]
      }
    ]
  }
}
```

It fires only when the command actually runs `git commit` (`git -C <dir> commit` and `git -c k=v commit` included) and only when staged blobs carry a marker. It matches `<<<<<<<` and `>>>>>>>` (each followed by a space) at line start but deliberately **not** a bare `=======`, which is an ordinary RST section underline and would otherwise deny every docs commit. Any error, non-repo cwd or unreadable diff allows the command — the gate never blocks on its own failure.

Verify it against both directions before relying on it: stage a file containing a real marker (must deny) and a `.rst` file with a `=======` underline (must allow).

## Recipe 7: Block a git write inside the reference `main/` worktree

`references/advanced-git.md` states that `main/` is reference only. The rule
gets broken anyway because breaking it needs no intent: one Bash call omits its
`cd`, inherits the working directory of an earlier call, and the commit lands on
the shared branch locally — where a later push or a `jj git export` moves it
under every sibling worktree. Prose cannot catch an inherited working directory;
a gate reads it out of the payload.

```bash
cp <skill>/scripts/reference-worktree-gate.py ~/.claude/hooks/
chmod +x ~/.claude/hooks/reference-worktree-gate.py
```

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          { "type": "command", "command": "python3 $HOME/.claude/hooks/reference-worktree-gate.py" }
        ]
      }
    ]
  }
}
```

It denies `commit`, `add`, `merge`, `rebase`, `cherry-pick`, `revert`, `am`,
`stash` and `reset --hard` when the effective directory is a `main/` (or
`master/`) that sits beside a `.bare`. It deliberately does **not** deny
`git -C <path> …` or a call that starts with `cd <path> &&` — both name where the
write lands, which is the shape it is steering toward — nor reads, `git fetch`,
or `git worktree add`, which are what the directory is for.

Nor `git merge --ff-only` / `git pull --ff-only`: the reference checkout has to
be *current* to serve as a base, so refreshing it is the directory's purpose and
a fast-forward can neither create a commit nor discard work. `reset --hard`
reaches the same state by discarding and stays refused. (That exemption is not
theory — the gate blocked its own author's `reset --hard` in `main/` minutes
after installation, which is how the over-block was found.) Roots default to
`~/projects` and `~/p`; set `GIT_WORKTREE_ROOTS` to a colon-separated list for
others.

Already have a Bash gate? Extend it instead of adding a second hook — the
directory test is three lines (`basename in {main,master}`, parent under a known
root, `.bare` sibling exists) and reusing one hook keeps the denial messages in
one place.

Verify both directions before relying on it: `python3 scripts/test_reference_worktree_gate.py`
builds a throwaway layout and checks that a commit in `main/` denies while
`git -C <branch> commit` and a commit in a branch worktree pass.

## Anti-Patterns

| Anti-pattern | Why wrong | Fix |
|--------------|-----------|-----|
| Using `xargs` on stdin JSON | xargs splits on spaces; breaks paths with spaces | `{ read -r F; ... "$F"; }` pattern |
| Forgetting `2>/dev/null \|\| true` on PostToolUse | Hook failure pollutes transcript | Wrap non-blocking hooks |
| `Write\|Edit` matcher without file-path extraction | Hook runs on wrong files | `jq -r '.tool_input.file_path'` |
| Blocking hooks that hit flaky services | One GitHub-API outage blocks all merges | Soft-fail: warn instead of deny for infra-dependent gates |
| Per-hook large shell scripts inline in JSON | Unreadable, un-testable | Keep inline ≤3 lines; call external script for more |
| An exception the gate reads from the environment | The hook is its own process; a `VAR=1 cmd` prefix never reaches it, so the documented way out is inert | Read it off the command text, anchored as a leading assignment, and copy the mechanism from the gate already shipping in that hook |
| A deny text whose promises nothing tests | The message is the contract; an untested promise is usually the case the gate gets wrong | One test per clause of the message — see below |
| A gate built from an incident that covers one command shape | An incident is plural; the shape you remember is rarely the only one it used | Extract every command shape from the transcript and assert the predicate on each |

### The deny message is a specification

Whatever a denial says is what its author will be held to, and the exception
a message carves out is the case most likely to be wrong — it is the one the
implementation had to think about separately. Turn each clause into a test
before shipping the gate.

The forge-body language gate is the worked example. Its first message made
three claims, and the gate honoured one of them:

| Clause of the message | Test | First version |
|---|---|---|
| a German body is denied | German prose → `deny` | held |
| quoting a German string inside an English body "is fine" | English body with a German stack trace → not `deny` | denied it |
| `FORGE_LANGUAGE_GATE_OFF=1` exempts a German repository | the documented command verbatim → not `deny` | inert: read from the environment, which a Bash prefix never reaches |

Both failures were found by writing the tests from the message rather than
from the implementation. A fourth clause — that the exemption is a prefix and
not a mention — entered the message only with the fix, which is itself the
pattern: sharpening a promise is how the missing case gets named, so
re-derive the tests whenever the message changes.

A gate that denies also needs its threshold calibrated against a negative
corpus wider than the documents that motivated it. In that gate a German
function-word marker list contained `mit`, which is the licence every skill
repository names. A false deny blocks legitimate work, so in a denying gate a
marker that fires on the negative corpus is worse than a missing one — and
the calibration belongs in a test rather than a comment, because a marker
list is a decision and a comment cannot fail when the decision is reversed.
