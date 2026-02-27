#!/usr/bin/env python3
"""
PreToolUse hook to validate git commands for best practices.
Checks conventional commits, branch naming, and common mistakes.
"""

import sys
import re
import json

# Conventional commit pattern
CONVENTIONAL_COMMIT_PATTERN = (
    r"^(feat|fix|docs|style|refactor|perf|test|build|ci|chore|revert)(\(.+\))?!?:\s.+"
)

# Git command patterns to check
CHECKS = [
    {
        "pattern": r'git\s+commit\s+.*-m\s*["\']([^"\']+)["\']',
        "check": "conventional_commit",
        "extract_group": 1,
    },
    {
        "pattern": r"git\s+checkout\s+-b\s+(\S+)",
        "check": "branch_name",
        "extract_group": 1,
    },
    {
        "pattern": r"git\s+push\s+(-f|--force)\s",
        "check": "force_push",
    },
    {
        "pattern": r"git\s+reset\s+--hard",
        "check": "hard_reset",
    },
    {
        "pattern": r"git\s+rebase\s+-i",
        "check": "interactive_rebase",
    },
    {
        "pattern": r"git\s+commit\s+--amend",
        "check": "amend_commit",
    },
]


def check_conventional_commit(message: str) -> str | None:
    """Validate commit message follows conventional commits."""
    if not re.match(CONVENTIONAL_COMMIT_PATTERN, message):
        return f"""Commit message doesn't follow Conventional Commits format.

Expected: <type>(<scope>): <description>
Types: feat, fix, docs, style, refactor, perf, test, build, ci, chore, revert

Examples:
  feat: add user authentication
  fix(api): handle null response
  docs: update README installation section

Your message: "{message[:50]}..." """
    return None


def check_branch_name(name: str) -> str | None:
    """Validate branch name follows conventions."""
    valid_patterns = [
        r"^(feature|feat|fix|bugfix|hotfix|release|chore|docs)/[\w-]+$",
        r"^(main|master|develop|staging)$",
    ]
    if not any(re.match(p, name) for p in valid_patterns):
        return f"""Branch name '{name}' doesn't follow conventions.

Recommended patterns:
  feature/description-here
  fix/issue-description
  hotfix/critical-fix
  release/v1.2.3"""
    return None


def check_command(command: str) -> list[dict]:
    """Check git command for best practices."""
    warnings = []

    for check in CHECKS:
        match = re.search(check["pattern"], command, re.IGNORECASE)
        if not match:
            continue

        check_type = check["check"]

        if check_type == "conventional_commit":
            msg = match.group(check.get("extract_group", 0))
            warning = check_conventional_commit(msg)
            if warning:
                warnings.append({"severity": "info", "message": warning})

        elif check_type == "branch_name":
            name = match.group(check.get("extract_group", 0))
            warning = check_branch_name(name)
            if warning:
                warnings.append({"severity": "info", "message": warning})

        elif check_type == "force_push":
            warnings.append(
                {
                    "severity": "warning",
                    "message": "Force push can overwrite remote history. Ensure this is intentional.",
                }
            )

        elif check_type == "hard_reset":
            warnings.append(
                {
                    "severity": "warning",
                    "message": "Hard reset discards uncommitted changes permanently.",
                }
            )

        elif check_type == "interactive_rebase":
            warnings.append(
                {
                    "severity": "info",
                    "message": "Interactive rebase requires manual input - not supported in this environment.",
                }
            )

        elif check_type == "amend_commit":
            warnings.append(
                {
                    "severity": "info",
                    "message": "Amending commits rewrites history. Avoid on pushed commits.",
                }
            )

    return warnings


def main():
    try:
        input_data = sys.stdin.read()
    except Exception:
        return

    if not input_data:
        return

    try:
        data = json.loads(input_data)
        command = data.get("command", "")
    except (json.JSONDecodeError, TypeError):
        command = input_data

    if not command or "git" not in command.lower():
        return

    warnings = check_command(command)

    if warnings:
        severity_icons = {"warning": "⚠️", "info": "ℹ️", "error": "❌"}
        output_lines = []
        for w in warnings:
            icon = severity_icons.get(w["severity"], "•")
            output_lines.append(f"{icon} {w['message']}")

        print(f"""<system-reminder>
Git workflow check:
{chr(10).join(output_lines)}

See git-workflow skill for best practices.
</system-reminder>""")


if __name__ == "__main__":
    main()
