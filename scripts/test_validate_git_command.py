"""Tests for the PreToolUse command validator.

Run with: python3 -m unittest discover -s scripts -p 'test_*.py'

The merge-readiness cases are the commands that motivated that check: asking
GitHub whether a pull request can merge, rather than pr-status.sh, hides the
two states that usually block it. The rest of the file guards the checks that
were already here so the new one cannot quietly change their behaviour.
"""

import json
import subprocess
import sys
import unittest
from pathlib import Path
from typing import ClassVar

HOOK = Path(__file__).with_name("validate_git_command.py")


def decision(output: str) -> str:
    """The permissionDecision the hook returned, or '' when it stayed advisory."""
    try:
        return json.loads(output)["hookSpecificOutput"]["permissionDecision"]
    except (json.JSONDecodeError, KeyError, TypeError):
        return ""


def run_hook(command: str) -> str:
    """Feed a command to the hook and return whatever it printed."""
    result = subprocess.run(
        [sys.executable, str(HOOK)],
        input=json.dumps({"command": command}),
        capture_output=True,
        text=True,
        check=False,
    )
    return result.stdout


class MergeReadinessGate(unittest.TestCase):
    WARNS: ClassVar[list[tuple[str, str]]] = [
        (
            "gh api mergeable_state",
            "gh api repos/netresearch/t3x-nr-llm/pulls/619 --jq .mergeable_state",
        ),
        (
            "gh pr view mergeStateStatus",
            "gh pr view 43 -R netresearch/t3x-contexts --json state,mergeStateStatus",
        ),
        (
            "reviewDecision is the same question",
            "gh pr view 12 -R o/r --json reviewDecision",
        ),
        (
            "inside a loop over several pull requests",
            "for n in 1 2; do gh api repos/o/r/pulls/$n --jq .mergeable_state; done",
        ),
    ]

    QUIET: ClassVar[list[tuple[str, str]]] = [
        (
            "pr-status.sh is the recommended shape",
            "pr-status.sh -R netresearch/t3x-nr-llm 619 --watch",
        ),
        (
            "reading the head sha is not a merge-readiness question",
            "gh pr view 619 -R o/r --json headRefOid --jq .headRefOid",
        ),
        (
            "reading review comments",
            "gh api repos/o/r/pulls/619/comments --jq '.[].body'",
        ),
        (
            "the isRequired deep dive names the unmet context",
            "gh api graphql -f query='{...isRequired(pullRequestNumber:619)... mergeStateStatus}'",
        ),
        (
            "merging itself",
            "gh pr merge 619 -R o/r --merge",
        ),
        (
            "the word in prose, not a query",
            'git commit -m "explain why mergeStateStatus alone is not enough"',
        ),
    ]

    def test_asking_github_directly_is_denied(self) -> None:
        for name, command in self.WARNS:
            with self.subTest(name):
                output = run_hook(command)
                self.assertIn("pr-status.sh", output, name)
                self.assertEqual("deny", decision(output), name)

    def test_legitimate_commands_are_not_denied(self) -> None:
        for name, command in self.QUIET:
            with self.subTest(name):
                output = run_hook(command)
                self.assertNotIn("Merge readiness", output, name)
                self.assertNotEqual("deny", decision(output), name)


class ExistingChecks(unittest.TestCase):
    def test_non_conventional_commit_message_warns(self) -> None:
        self.assertIn("onventional", run_hook('git commit -m "fixed stuff"'))

    def test_conventional_commit_message_stays_quiet(self) -> None:
        self.assertNotIn(
            "onventional", run_hook('git commit -m "fix: correct the tally"')
        )

    def test_force_push_warns(self) -> None:
        self.assertIn("Force push", run_hook("git push -f origin main"))

    def test_hard_reset_warns(self) -> None:
        self.assertIn("Hard reset", run_hook("git reset --hard origin/main"))

    def test_unrelated_command_produces_nothing(self) -> None:
        self.assertEqual("", run_hook("ls -la"))


if __name__ == "__main__":
    unittest.main()
