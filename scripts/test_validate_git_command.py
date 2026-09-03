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
import tempfile
import time
import unittest
import unittest.mock
from pathlib import Path
from typing import ClassVar

sys.path.insert(0, str(Path(__file__).resolve().parent))

from validate_git_command import GERMAN_MARKERS

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
            'git -C /repo commit -m "explain why mergeStateStatus alone is not enough"',
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
        self.assertIn(
            "onventional", run_hook('cd /repo && git commit -m "fixed stuff"')
        )

    def test_conventional_commit_message_stays_quiet(self) -> None:
        self.assertNotIn(
            "onventional",
            run_hook('cd /repo && git commit -m "fix: correct the tally"'),
        )

    def test_force_push_warns(self) -> None:
        self.assertIn("Force push", run_hook("cd /repo && git push -f origin main"))

    def test_hard_reset_warns(self) -> None:
        self.assertIn(
            "Hard reset", run_hook("cd /repo && git reset --hard origin/main")
        )

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

    def test_marker_list_excludes_the_words_that_collide_with_english(self) -> None:
        """Pins the calibration decisions, each of which cost a false positive.

        Every word here is German and was in an early draft of the list. Each
        is also ordinary English or a term the fleet's own prose uses — `mit`
        is the licence every skill repository names — so re-adding one makes
        the gate deny English bodies. A list is a decision, and this is the
        assertion that makes the decision fail loudly when it is reversed.
        """
        for word in ("mit", "das", "von", "hat", "die", "man", "war", "so", "in"):
            self.assertNotIn(word, GERMAN_MARKERS, f"{word!r} also occurs in English")

    def test_an_english_body_about_licences_is_not_denied(self) -> None:
        # The body shape that made `mit` untenable, run through the real gate
        # rather than through a re-implementation of its thresholds.
        body = (
            "This adds the missing licence headers. Every package here is MIT, "
            "so the header names the MIT licence and the holder, and the SPDX "
            "identifier stays MIT-only. The one exception is the vendored "
            "parser, which is BSD, and it keeps its own header verbatim."
        )
        out = run_hook(f"gh pr create --title x --body '{body}'")
        self.assertNotEqual("deny", decision(out))

    def test_commit_message_is_not_a_forge_body(self) -> None:
        # Commit messages are out of scope for this gate; only forge bodies.
        out = run_hook(f"git -C /repo commit -m 'feat: x\n\n{self.GERMAN}'")
        self.assertNotEqual("deny", decision(out))


class AdvisoryOncePerSession(unittest.TestCase):
    """The two advisories restate a general rule, not a fact about the command.

    Repeating one on every matching call is noise paid in the user's attention:
    each reaches the transcript via systemMessage. Fire once per session per
    advisory — but a marker-storage problem must never suppress the warning.
    """

    ADVISORY_CMD = "git status"  # matches GIT_MEASURING_READ without a -C/cd
    POLL_CMD = "while true; do gh run list --limit 5; sleep 30; done"
    BOTH_CMD = (
        "while true; do gh run list --limit 5; git log --oneline -1; sleep 30; done"
    )

    def setUp(self) -> None:
        self.runtime = tempfile.TemporaryDirectory()
        self.addCleanup(self.runtime.cleanup)

    def run_hook_session(
        self,
        command: str,
        session: "str | None",
        runtime_dir: "str | None" = None,
        fallback_dir: "str | None" = None,
    ) -> str:
        env = dict(os.environ)
        env["XDG_RUNTIME_DIR"] = (
            runtime_dir if runtime_dir is not None else self.runtime.name
        )
        # The hook falls back to the temp directory when XDG_RUNTIME_DIR cannot
        # hold markers, so the temp directory has to be isolated per test too.
        # Left at the real /tmp, markers from one run silence the next one and
        # the suite passes or fails depending on what an earlier run left there.
        fallback = fallback_dir if fallback_dir is not None else self.runtime.name
        for var in ("TMPDIR", "TEMP", "TMP"):
            env[var] = fallback
        payload: dict = {"command": command}
        if session is not None:
            payload["session_id"] = session
        result = subprocess.run(
            [sys.executable, str(HOOK)],
            input=json.dumps(payload),
            capture_output=True,
            text=True,
            env=env,
            timeout=30,
            check=False,
        )
        return result.stdout

    def test_advisory_fires_once_per_session_per_advisory(self) -> None:
        first = self.run_hook_session(self.ADVISORY_CMD, "sess-1")
        self.assertIn("git-workflow:", first)
        second = self.run_hook_session(self.ADVISORY_CMD, "sess-1")
        self.assertEqual("", second.strip(), "same session, same advisory: stay quiet")

    def test_a_different_session_fires_its_own_first_warning(self) -> None:
        self.run_hook_session(self.ADVISORY_CMD, "sess-1")
        other = self.run_hook_session(self.ADVISORY_CMD, "sess-2")
        self.assertIn("git-workflow:", other)

    def test_without_a_session_id_every_call_warns(self) -> None:
        first = self.run_hook_session(self.ADVISORY_CMD, None)
        second = self.run_hook_session(self.ADVISORY_CMD, None)
        self.assertIn("git-workflow:", first)
        self.assertIn("git-workflow:", second)

    def test_an_unusable_runtime_dir_still_reaches_the_user_the_first_time(
        self,
    ) -> None:
        # XDG_RUNTIME_DIR names an existing FILE, so no marker can be written
        # there. The warning must still reach the author.
        blocker = Path(self.runtime.name) / "blocker"
        blocker.write_text("not a directory\n")
        out = self.run_hook_session(self.ADVISORY_CMD, "sess-3", str(blocker))
        self.assertIn("git-workflow:", out)

    def test_a_spent_advisory_does_not_swallow_the_other_ones_first_warning(
        self,
    ) -> None:
        # One command can match both advisories. Once the poll advisory has
        # fired, a combined command must still deliver the other advisory's
        # first warning instead of returning early on the spent one.
        first = self.run_hook_session(self.POLL_CMD, "sess-4")
        self.assertIn("Waiting on workflow runs", first)
        combined = self.run_hook_session(self.BOTH_CMD, "sess-4")
        self.assertIn("inherits its working directory", combined)

    def test_a_permanently_unusable_runtime_dir_still_dedupes(self) -> None:
        # XDG_RUNTIME_DIR is exported by the login shell but the directory does
        # not exist and cannot be created (no systemd user session -- the normal
        # case under WSL, in containers, and on cron-launched sessions). Falling
        # back to "not fired" then repeats on EVERY matching command for the
        # life of the session: four identical warnings in a row on 2026-09-02,
        # which is what the once-per-session rule exists to prevent. A location
        # that cannot hold markers must be replaced by one that can, not turned
        # into permission to storm.
        unusable = Path(self.runtime.name) / "blocker" / "nested"
        unusable.parent.write_text("not a directory\n")
        first = self.run_hook_session(self.ADVISORY_CMD, "sess-6", str(unusable))
        self.assertIn("git-workflow:", first)
        second = self.run_hook_session(self.ADVISORY_CMD, "sess-6", str(unusable))
        self.assertEqual("", second.strip(), "unusable runtime dir: still dedupe")

    def test_the_fallback_is_the_temp_directory_the_process_would_use(self) -> None:
        # Naming the location is what makes the previous test more than "it
        # went quiet somehow": the marker has to be findable where the hook
        # says it puts it.
        unusable = Path(self.runtime.name) / "blocker2" / "nested"
        unusable.parent.write_text("not a directory\n")
        self.run_hook_session(self.ADVISORY_CMD, "sess-7", str(unusable))
        marker = (
            Path(self.runtime.name)
            / "git-workflow-advisories"
            / "sess-7.git_read_without_named_dir"
        )
        self.assertTrue(marker.exists(), f"expected the marker at {marker}")

    def test_a_marker_older_than_the_rearm_window_fires_again_once(self) -> None:
        # A session can run for days and its context gets compacted, so a
        # warning delivered once at the start is gone by then. An old marker
        # re-arms the advisory: fire again, restart the window, go quiet again.
        self.run_hook_session(self.ADVISORY_CMD, "sess-5")
        marker = (
            Path(self.runtime.name)
            / "git-workflow-advisories"
            / "sess-5.git_read_without_named_dir"
        )
        old = time.time() - 7 * 60 * 60
        os.utime(marker, (old, old))
        again = self.run_hook_session(self.ADVISORY_CMD, "sess-5")
        self.assertIn("git-workflow:", again)
        quiet = self.run_hook_session(self.ADVISORY_CMD, "sess-5")
        self.assertEqual("", quiet.strip(), "re-arm must also re-mark: quiet again")


class NamedDirectoryAdvisoryScope(unittest.TestCase):
    """A `cd` opening a quoted payload names the directory just as well.

    `ssh host 'cd /etc && git log -1'` and `bash -c 'cd /srv && git status'`
    both say where the measurement happens. The advisory used to fire anyway,
    because it only recognised a `cd` preceded by a statement separator and a
    quote is not one -- so every remote inspection drew the same paragraph
    (four in a row on 2026-09-02, on an ssh loop that did `cd /etc` first).
    """

    def fired(self, command: str) -> bool:
        return "inherits its working directory" in run_hook(command)

    def test_a_bare_measurement_still_warns(self) -> None:
        self.assertTrue(self.fired("git status"))

    def test_a_cd_opening_a_quoted_payload_counts_as_named(self) -> None:
        self.assertFalse(self.fired("bash -c 'cd /srv/app && git status'"))

    def test_ssh_with_options_and_a_remote_cd(self) -> None:
        self.assertFalse(
            self.fired(
                "timeout 60 ssh -o BatchMode=yes root@nova.nr 'cd /etc && git log -1'"
            )
        )

    def test_a_quoted_payload_without_a_cd_never_matched_anyway(self) -> None:
        # Characterization: `git` sits right behind the quote, which is not a
        # statement separator, so the measurement pattern never matched here.
        # Recorded so a future widening of that pattern has to face this case.
        self.assertFalse(self.fired("ssh root@nova.nr 'git status'"))
        self.assertFalse(self.fired("docker exec app sh -c 'git rev-parse HEAD'"))

    def test_a_cd_in_a_subshell_counts_as_named(self) -> None:
        # The measurement pattern accepts `(` and `$(` as separators before
        # `git`, so these match and then have to find their `cd`. Recognising
        # the git command but not the cd that precedes it inside the same
        # subshell is the advisory firing on a command that names its directory.
        self.assertFalse(self.fired("(cd /etc && git status)"))
        self.assertFalse(self.fired("(cd /etc; git status)"))

    def test_a_cd_in_a_command_substitution_counts_as_named(self) -> None:
        self.assertFalse(self.fired("$(cd /etc && git log -1)"))
        self.assertFalse(self.fired("x=$(cd /srv && git rev-parse HEAD)"))

    def test_a_subshell_without_a_cd_still_warns(self) -> None:
        # The widening must not swallow the case the advisory exists for.
        self.assertTrue(self.fired("(git status)"))
        self.assertTrue(self.fired("x=$(git rev-parse HEAD)"))

    def test_a_cd_in_an_earlier_payload_does_not_silence_a_local_slip(self) -> None:
        # The remote `cd` belongs to the ssh payload; the local `git status`
        # after it is exactly the slip this advisory exists for.
        self.assertTrue(self.fired("ssh host 'cd /etc && ls'; git status"))

    def test_a_local_measurement_after_a_remote_one_still_warns(self) -> None:
        self.assertTrue(self.fired("ssh host 'git status'; git log --oneline -1"))

    def test_a_closed_subshell_cd_does_not_reach_the_next_command(self) -> None:
        # `cd` inside a subshell dies with the subshell. Accepting it for a
        # measurement that runs after the closing paren is the advisory going
        # quiet on precisely the slip it exists for.
        self.assertTrue(self.fired("(cd /etc && ls); git status"))
        self.assertTrue(self.fired("x=$(cd /etc && pwd); git status"))

    def test_a_cd_deeper_inside_a_closed_payload_does_not_leak_out(self) -> None:
        # Same for a remote payload: the earlier test only covered a `cd` at
        # the start of the quoted run, which no separator preceded anyway.
        self.assertTrue(self.fired('ssh host "echo ok; cd /etc && ls"; git status'))

    def test_every_measurement_is_checked_not_just_the_first(self) -> None:
        # The remote measurement is named by its own `cd`; the local one that
        # follows is not, and it is the one worth warning about.
        self.assertTrue(self.fired("ssh host 'cd /etc && git status'; git status"))


class NowhereToStoreAMarker(unittest.TestCase):
    """When no location can hold a marker, the warning still reaches the author.

    This cannot be provoked through the environment: `tempfile.gettempdir()`
    validates its candidates and lands on /tmp whatever TMPDIR says, so the
    branch is only reachable where /tmp itself is unwritable. Exercised
    directly, because a defensive branch nothing ever runs is a claim, not a
    guarantee.
    """

    def test_every_candidate_failing_reads_as_not_fired(self) -> None:
        import validate_git_command as vgc

        payload = {"session_id": "sess-nowhere"}
        with unittest.mock.patch.object(
            vgc.os, "makedirs", side_effect=OSError("read-only")
        ):
            first = vgc._advisory_already_fired(payload, "git_read_without_named_dir")
            second = vgc._advisory_already_fired(payload, "git_read_without_named_dir")
        self.assertFalse(first)
        self.assertFalse(second, "storage failure must never read as 'already seen'")

    def test_a_root_that_takes_the_directory_but_refuses_the_marker_falls_through(
        self,
    ) -> None:
        # makedirs succeeding does not mean the marker can be written: the
        # advisory directory may exist and be unwritable. Committing to the
        # first root that accepts makedirs leaves the dedupe off for good,
        # which is the storm this whole mechanism exists to prevent.
        import validate_git_command as vgc

        with (
            tempfile.TemporaryDirectory() as runtime,
            tempfile.TemporaryDirectory() as fallback,
        ):
            hostile = Path(runtime) / "git-workflow-advisories"
            hostile.mkdir()
            hostile.chmod(0o500)  # listable, not writable
            try:
                with (
                    unittest.mock.patch.dict(
                        vgc.os.environ, {"XDG_RUNTIME_DIR": runtime}
                    ),
                    unittest.mock.patch.object(
                        vgc.tempfile, "gettempdir", return_value=fallback
                    ),
                ):
                    first = vgc._advisory_already_fired(
                        {"session_id": "sess-fall"}, "git_read_without_named_dir"
                    )
                    second = vgc._advisory_already_fired(
                        {"session_id": "sess-fall"}, "git_read_without_named_dir"
                    )
            finally:
                # restore before the TemporaryDirectory tries to remove it
                hostile.chmod(0o700)
            self.assertFalse(first)
            self.assertTrue(second, "the fallback root must still dedupe")
            self.assertTrue(
                (
                    Path(fallback)
                    / "git-workflow-advisories"
                    / "sess-fall.git_read_without_named_dir"
                ).exists()
            )

    def test_the_runtime_dir_is_preferred_when_it_works(self) -> None:
        import validate_git_command as vgc

        with (
            tempfile.TemporaryDirectory() as runtime,
            tempfile.TemporaryDirectory() as fallback,
        ):
            with (
                unittest.mock.patch.dict(vgc.os.environ, {"XDG_RUNTIME_DIR": runtime}),
                unittest.mock.patch.object(
                    vgc.tempfile, "gettempdir", return_value=fallback
                ),
            ):
                vgc._advisory_already_fired(
                    {"session_id": "sess-pref"}, "git_read_without_named_dir"
                )
            marker = (
                Path(runtime)
                / "git-workflow-advisories"
                / "sess-pref.git_read_without_named_dir"
            )
            self.assertTrue(marker.exists(), "a working XDG_RUNTIME_DIR wins")
            self.assertFalse((Path(fallback) / "git-workflow-advisories").exists())


if __name__ == "__main__":
    unittest.main()


class NamedDirectoryWriteGate(unittest.TestCase):
    """A git write must say where it runs; a read only gets the advisory.

    The read advisory fires once per session and is easy to read past; on
    2026-09-03 a `git push` without a directory ran in the wrong checkout and
    was saved only by a branch that did not exist there. Writes are denied
    until they name their directory with `-C` or a `cd` in the same scope.
    """

    DENIED: ClassVar[list[str]] = [
        "git commit -S -s -m 'feat: x'",
        "git push origin feat/x",
        "git push --force-with-lease origin feat/x",
        "git reset --hard HEAD~1",
        "git cherry-pick abc1234",
        "git rebase -S origin/main",
        "git worktree remove ../x",
        "git -c commit.gpgsign=true commit -m x",
        "git add -A; git commit -m x",
    ]
    ALLOWED: ClassVar[list[str]] = [
        "git -C /home/u/repo commit -m x",
        "git -C .bare worktree add ../x -b x origin/main",
        "cd /home/u/repo && git push origin feat/x",
        "cd /home/u/repo && git add a.txt && git commit -m x",
        "bash -c 'cd /srv/app && git pull --ff-only'",
        "git status",
        "git log --oneline -3",
        "git -C /home/u/repo commit -m x && git log --oneline -1",
        "DESTRUCTIVE_GIT_GATE_OFF=1 git commit -m x",
        "gh pr create --draft",
    ]

    def test_writes_without_a_named_directory_are_denied(self) -> None:
        for command in self.DENIED:
            with self.subTest(command=command):
                out = run_hook(command)
                self.assertEqual("deny", decision(out), out)
                self.assertIn("without naming its directory", out)

    def test_named_directories_reads_and_the_escape_hatch_pass(self) -> None:
        for command in self.ALLOWED:
            with self.subTest(command=command):
                self.assertNotEqual("deny", decision(run_hook(command)), command)

    def test_the_message_names_the_subcommand_and_both_fixes(self) -> None:
        out = run_hook("git push origin main")
        self.assertIn("`git push`", out)
        self.assertIn("git -C /abs/path <subcommand>", out)
        self.assertIn("cd /abs/path && git <subcommand>", out)
