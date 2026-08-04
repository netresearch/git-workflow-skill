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

Blocks any `gh pr merge` invocation that would merge a PR with unresolved threads or missing approval.

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


The hook denies `gh pr merge` when review threads are unresolved or `mergeStateStatus != CLEAN` (`UNSTABLE` — a non-required check red — is still a deny). It deliberately does not gate on `reviewDecision`: repos without a required-approval rule report `""` and merge legitimately when CLEAN. It parses the three PR-reference forms `gh pr merge` accepts (plain number, full URL, `owner/repo#N`) and honors an explicit `--repo`/`-R` flag — without that, the PR number resolves against the CWD repo and produces false denials when the command targets another repo. If parsing or the PR lookup fails, the hook allows the call rather than producing false-positive denies. Two usage caveats: the hook evaluates at Bash-call time, so never chain a wait-until-CLEAN loop and the merge in one invocation (wait in one call, merge in the next); and it is a personal-harness gate — server-side branch protection remains the authoritative enforcement.

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

## Anti-Patterns

| Anti-pattern | Why wrong | Fix |
|--------------|-----------|-----|
| Using `xargs` on stdin JSON | xargs splits on spaces; breaks paths with spaces | `{ read -r F; ... "$F"; }` pattern |
| Forgetting `2>/dev/null \|\| true` on PostToolUse | Hook failure pollutes transcript | Wrap non-blocking hooks |
| `Write\|Edit` matcher without file-path extraction | Hook runs on wrong files | `jq -r '.tool_input.file_path'` |
| Blocking hooks that hit flaky services | One GitHub-API outage blocks all merges | Soft-fail: warn instead of deny for infra-dependent gates |
| Per-hook large shell scripts inline in JSON | Unreadable, un-testable | Keep inline ≤3 lines; call external script for more |
