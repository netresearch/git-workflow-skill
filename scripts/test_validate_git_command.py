"""Tests for the PreToolUse command validator.

Run with: python3 -m unittest discover -s scripts -p 'test_*.py'

The merge-readiness cases are the commands that motivated that check: asking
GitHub whether a pull request can merge, rather than pr-status.sh, hides the
two states that usually block it. The rest of the file guards the checks that
were already here so the new one cannot quietly change their behaviour.
"""

import json
import os
import subprocess
import sys
import unittest
from pathlib import Path
from typing import ClassVar

sys.path.insert(0, str(Path(__file__).resolve().parent))

from validate_git_command import german_prose

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


class ForgeBodyLanguageGate(unittest.TestCase):
    """A forge body is read by whoever finds the repository, not by its author.

    The repositories are English, so a German body excludes every reader who
    does not share the author's chat language — and the chat language is where
    it comes from: an agent that has been conversing in German carries it into
    the PR without noticing. Prose said so already and did not hold.
    """

    GERMAN = (
        "Der Review hat den ersten Stand nicht durchgehen lassen. Drei der vier "
        "Zählmuster sind woertliches Markup, also lassen ein hinzugefuegtes "
        "Attribut oder ein Umbruch sie auf beiden Seiten auf null fallen, und "
        "der Vergleich besteht dann. Das ist jetzt behoben und nachgemessen."
    )
    ENGLISH = (
        "The review did not let the first version through. Three of the four "
        "count patterns are literal markup, so an added attribute or a reflow "
        "drops them to zero on both pages at once and the comparison passes. "
        "That is fixed now and measured."
    )

    def test_german_body_is_denied(self) -> None:
        out = run_hook(f"gh pr create --title x --body '{self.GERMAN}'")
        self.assertEqual("deny", decision(out))

    def test_denial_names_the_language_rule(self) -> None:
        out = run_hook(f"gh pr create --title x --body '{self.GERMAN}'")
        self.assertIn("English", out)

    def test_english_body_passes(self) -> None:
        out = run_hook(f"gh pr create --title x --body '{self.ENGLISH}'")
        self.assertNotEqual("deny", decision(out))

    def test_german_review_comment_is_denied(self) -> None:
        out = run_hook(f"gh pr comment 3 -R o/r --body '{self.GERMAN}'")
        self.assertEqual("deny", decision(out))

    def test_english_body_naming_german_identifiers_passes(self) -> None:
        # An English body may quote German strings — a test fixture, a UI label,
        # an error message. Those must not read as a German body.
        body = (
            "The seed fixture contains the label 'Nicht gefunden' and the error "
            "'Der Wert ist ungueltig', both asserted verbatim in the test. This "
            "PR only changes the encoding used when they are written to disk."
        )
        out = run_hook(f"gh pr create --title x --body '{body}'")
        self.assertNotEqual("deny", decision(out))

    def test_short_english_reply_passes(self) -> None:
        out = run_hook("gh pr comment 3 -R o/r --body 'Fixed in abc1234.'")
        self.assertNotEqual("deny", decision(out))

    def test_override_prefix_lets_a_german_body_through(self) -> None:
        # The hook is its own process, so the override has to be read off the
        # command text; an environment lookup would never see the prefix.
        out = run_hook(
            f"FORGE_LANGUAGE_GATE_OFF=1 gh pr create --title x --body '{self.GERMAN}'"
        )
        self.assertNotEqual("deny", decision(out))

    def test_english_body_quoting_a_german_log_passes(self) -> None:
        # The case the denial message promises: a German error log inside an
        # English body. Fenced blocks and quoted strings are not prose.
        body = (
            "The importer aborts on the second batch. The server returns this, "
            "verbatim:\n\n```\nDer Vorgang wurde abgebrochen, weil die Datei "
            "nicht gelesen werden konnte und der Puffer nicht mehr frei ist. "
            "Bitte pruefen Sie die Rechte und starten Sie den Import erneut.\n```\n\n"
            "The fix decodes the payload before the size check, so the buffer is "
            "never consulted on a partial read."
        )
        out = run_hook(f"gh pr create --title x --body '{body}'")
        self.assertNotEqual("deny", decision(out))

    def test_english_body_about_german_content_passes(self) -> None:
        body = (
            "This adds the German translation catalogue. The labels are stored "
            "under de/, the keys are unchanged, and the fallback stays English "
            "when a key is missing. The reviewer only needs to check that the "
            "plural forms resolve, since that is where the previous catalogue "
            "was wrong for counts above twelve."
        )
        out = run_hook(f"gh pr create --title x --body '{body}'")
        self.assertNotEqual("deny", decision(out))

    def test_german_review_body_is_denied(self) -> None:
        # `gh pr review` is how half of the incident's German text was posted.
        out = run_hook(f"gh pr review 3 -R o/r --comment --body '{self.GERMAN}'")
        self.assertEqual("deny", decision(out))

    def test_german_review_reply_via_api_is_denied(self) -> None:
        out = run_hook(
            f"gh api repos/o/r/pulls/comments/123/replies -f body='{self.GERMAN}'"
        )
        self.assertEqual("deny", decision(out))

    def test_german_glab_note_is_denied(self) -> None:
        out = run_hook(f"glab mr note 7 --message x --body '{self.GERMAN}'")
        self.assertEqual("deny", decision(out))

    def test_marker_named_inside_a_body_does_not_disable_the_gate(self) -> None:
        # The escape hatch is an assignment in front of the command, not the
        # string appearing anywhere in it.
        out = run_hook(
            "gh pr create --title x --body "
            f"'FORGE_LANGUAGE_GATE_OFF=1 is documented. {self.GERMAN}'"
        )
        self.assertEqual("deny", decision(out))

    def test_a_body_file_that_is_not_utf8_does_not_crash_the_hook(self) -> None:
        import tempfile

        with tempfile.NamedTemporaryFile("wb", suffix=".md", delete=False) as fh:
            fh.write(b"Fixed in abc1234. Raw byte: \xff\xfe and more text.")
            path = fh.name
        out = run_hook(f"gh pr comment 3 -R o/r --body-file {path}")
        os.unlink(path)
        # No traceback, and the other gates in the file still got their turn.
        self.assertNotIn("Traceback", out)

    def test_no_english_reference_file_in_the_fleet_is_denied(self) -> None:
        """The calibration corpus, as an assertion rather than a code comment.

        The marker list is a heuristic, and the only thing that keeps it honest
        is a negative corpus wider than the documents that motivated it: `mit`
        had to go because it is the licence every skill repository names. This
        feeds the skill's own English reference files through the gate and
        requires that none of them denies.
        """
        here = Path(__file__).resolve().parent.parent
        corpus = sorted((here / "skills").glob("*/references/*.md"))
        self.assertGreater(len(corpus), 3, "corpus too small to be evidence")
        denied = []
        for path in corpus:
            text = path.read_text(encoding="utf-8", errors="replace")
            distinct, share = german_prose(text)
            if distinct >= 6 and share >= 0.08:
                denied.append(f"{path.name} ({distinct} markers, {share:.0%})")
        self.assertEqual([], denied, "English reference prose must not trip the gate")

    def test_the_gate_still_fires_on_german_of_the_same_length(self) -> None:
        # Guards the other direction: a corpus test that passes because the
        # thresholds became unreachable would prove nothing.
        distinct, share = german_prose(self.GERMAN * 8)
        self.assertGreaterEqual(distinct, 6)
        self.assertGreaterEqual(share, 0.08)

    def test_commit_message_is_not_a_forge_body(self) -> None:
        # Commit messages are out of scope for this gate; only forge bodies.
        out = run_hook(f"git commit -m 'feat: x\n\n{self.GERMAN}'")
        self.assertNotEqual("deny", decision(out))


if __name__ == "__main__":
    unittest.main()
