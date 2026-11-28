# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: Netresearch DTT GmbH
"""Tests for the gates promoted from a harness-local hook (2026-08-15).

Run with: python3 -m unittest discover -s scripts -p 'test_*.py'

Each case is a command shape that occurred in a real session — the docstring of
the rule in validate_git_command.py names the incident it came from.
"""

import importlib.util
import json
import subprocess
import sys
import unittest
from pathlib import Path

HOOK = Path(__file__).with_name("validate_git_command.py")

_spec = importlib.util.spec_from_file_location("validate_git_command", HOOK)
hook = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(hook)

# Assembled rather than written out, so this file does not itself read as a
# poll loop to the very gate it is testing.
_POLL_WITHOUT_ARM = (
    "until gh run list --json status --jq '[.[]|select(.status!=\"completed\")]|length' "
    "| " + "grep" + " -q 0; do sleep 20; done"
)
_POLL_WITH_ARM = (
    "while :; do x=$(gh run view 1 --json conclusion --jq .conclusion); "
    'case "$x" in "" | err) echo "query failed"; break ;; '
    "failure) break ;; success) break ;; esac; sleep 20; done"
)


def decision(output: str) -> str:
    try:
        return json.loads(output)["hookSpecificOutput"]["permissionDecision"]
    except (json.JSONDecodeError, KeyError, TypeError):
        return ""


def run_hook(command: str) -> str:
    result = subprocess.run(
        [sys.executable, str(HOOK)],
        input=json.dumps({"command": command}),
        capture_output=True,
        text=True,
        check=False,
    )
    return result.stdout


class RunPoll(unittest.TestCase):
    """A run-poll is legitimate; two defects in how it is written are not."""

    def test_loop_without_failure_arm_warns(self) -> None:
        out = run_hook(_POLL_WITHOUT_ARM)
        self.assertIn("no branch for the query itself failing", out)
        self.assertNotEqual("deny", decision(out), "a run-poll must never be blocked")

    def test_loop_waiting_for_every_run_warns(self) -> None:
        self.assertIn("every run has finished", run_hook(_POLL_WITHOUT_ARM))

    def test_loop_with_failure_arm_and_early_exit_stays_quiet(self) -> None:
        self.assertEqual("", run_hook(_POLL_WITH_ARM))

    def test_single_run_query_is_not_a_loop(self) -> None:
        self.assertEqual("", run_hook("gh run list --limit 5"))


class BlanketGitAdd(unittest.TestCase):
    """`git add -A` / `.` with untracked files lying around is denied; named paths pass."""

    def setUp(self) -> None:
        import tempfile

        self.repo = tempfile.mkdtemp()
        subprocess.run(["git", "-C", self.repo, "init", "-q"], check=True)
        Path(self.repo, "tracked.txt").write_text("a\n")
        subprocess.run(["git", "-C", self.repo, "add", "tracked.txt"], check=True)
        subprocess.run(
            [
                "git",
                "-C",
                self.repo,
                "-c",
                "user.email=t@t",
                "-c",
                "user.name=t",
                "commit",
                "-qm",
                "init",
            ],
            check=True,
        )

    def tearDown(self) -> None:
        import shutil

        shutil.rmtree(self.repo, ignore_errors=True)

    def _run(self, command: str) -> str:
        result = subprocess.run(
            [sys.executable, str(HOOK)],
            input=json.dumps(
                {
                    "tool_name": "Bash",
                    "tool_input": {"command": command},
                    "cwd": self.repo,
                }
            ),
            capture_output=True,
            text=True,
            check=False,
        )
        return result.stdout

    def test_add_all_with_an_untracked_file_is_denied(self) -> None:
        Path(self.repo, "stray.txt").write_text("junk\n")
        out = self._run("git add -A && git commit -m x")
        self.assertEqual("deny", decision(out))
        self.assertIn("stray.txt", out)

    def test_add_dot_with_an_untracked_file_is_denied(self) -> None:
        Path(self.repo, "var").mkdir()
        Path(self.repo, "var", "cache.json").write_text("{}")
        self.assertEqual("deny", decision(self._run("git add .")))

    def test_add_all_on_a_clean_tree_passes(self) -> None:
        self.assertNotEqual("deny", decision(self._run("git add -A")))

    def test_add_all_with_only_tracked_edits_passes(self) -> None:
        Path(self.repo, "tracked.txt").write_text("b\n")
        self.assertNotEqual("deny", decision(self._run("git add -A")))

    def test_named_path_beside_an_untracked_file_passes(self) -> None:
        Path(self.repo, "stray.txt").write_text("junk\n")
        self.assertNotEqual("deny", decision(self._run("git add tracked.txt")))

    def test_named_directory_is_honoured(self) -> None:
        Path(self.repo, "stray.txt").write_text("junk\n")
        self.assertEqual("deny", decision(self._run(f"git -C {self.repo} add -A")))

    def test_escape_hatch(self) -> None:
        Path(self.repo, "stray.txt").write_text("junk\n")
        self.assertNotEqual(
            "deny", decision(self._run("DESTRUCTIVE_GIT_GATE_OFF=1 git add -A"))
        )


class GitReadDirectory(unittest.TestCase):
    """A measurement that does not say which repository it measured."""

    def test_bare_git_log_warns(self) -> None:
        out = run_hook("git log --oneline -3")
        self.assertIn("inherits its working directory", out)
        self.assertNotEqual("deny", decision(out))

    def test_dash_c_names_the_directory(self) -> None:
        self.assertNotIn(
            "inherits its working directory", run_hook("git -C /abs/p log --oneline -3")
        )

    def test_cd_in_the_same_invocation_names_the_directory(self) -> None:
        self.assertNotIn(
            "inherits its working directory", run_hook("cd /abs/p && git status")
        )

    def test_a_write_is_not_a_measurement(self) -> None:
        """Writes are the reference-worktree gate's business, not this one."""
        self.assertNotIn("inherits its working directory", run_hook("git add -A"))


class UnresolvableSha(unittest.TestCase):
    """A commit hash written from memory instead of looked up."""

    BODY = 'gh pr comment 1 --repo o/r --body "fixed in 8e1c9b0"'

    def test_a_comment_listing_is_no_published_body(self) -> None:
        # As denied on 2026-11-25: a session id filters a listing; nothing is posted.
        cmd = (
            "grep -rl GIT_DIR . | grep -v 83e8e253; gh api --paginate "
            "\"repos/o/r/pulls/comments?per_page=100\" --jq '.[].body'"
        )
        self.assertIsNone(hook.unresolvable_sha(cmd, resolve=lambda repo, token: False))

    def test_every_api_write_is_still_checked(self) -> None:
        for flag in (
            '-f body="fixed in 8e1c9b0"',
            "-F body=@b.md # 8e1c9b0",
            "--field body=8e1c9b0",
            "--raw-field body=8e1c9b0",
            "--input b.json # 8e1c9b0",
            "-X POST # 8e1c9b0",
            "--method PATCH # 8e1c9b0",
            "\\\n  -f body=8e1c9b0",
        ):
            with self.subTest(flag=flag):
                cmd = f"gh api repos/o/r/issues/1/comments {flag}"
                self.assertIsNotNone(
                    hook.unresolvable_sha(cmd, resolve=lambda repo, token: False)
                )

    def test_a_listing_does_not_cover_a_comment_beside_it(self) -> None:
        cmd = "gh api repos/o/r/issues/1/comments; " + self.BODY
        self.assertIsNotNone(
            hook.unresolvable_sha(cmd, resolve=lambda repo, token: False)
        )

    def test_unknown_hash_is_reported(self) -> None:
        reason = hook.unresolvable_sha(self.BODY, resolve=lambda repo, token: False)
        self.assertIsNotNone(reason)
        self.assertIn("8e1c9b0", reason)

    def test_known_hash_passes(self) -> None:
        self.assertIsNone(
            hook.unresolvable_sha(self.BODY, resolve=lambda repo, token: True)
        )

    def test_unreachable_forge_does_not_accuse(self) -> None:
        """A lookup that could not be made is no evidence the hash is invented."""
        self.assertIsNone(
            hook.unresolvable_sha(self.BODY, resolve=lambda repo, token: None)
        )

    def test_hash_inside_a_url_is_left_alone(self) -> None:
        """A URL may point at another repository entirely."""
        self.assertIsNone(
            hook.unresolvable_sha(
                'gh pr comment 1 --repo o/r --body "see https://x/commit/8e1c9b0"',
                resolve=lambda repo, token: False,
            )
        )

    def test_pull_request_number_is_not_a_hash(self) -> None:
        self.assertIsNone(
            hook.unresolvable_sha(
                'gh pr comment 1 --repo o/r --body "closes 1234567"',
                resolve=lambda repo, token: False,
            )
        )

    def test_quoted_heredoc_is_data_not_a_command(self) -> None:
        """Writing a file that documents a forge call must not be scanned."""
        cmd = (
            "cat <<'EOF' > doc.md\n"
            'gh pr comment 1 --repo o/r --body "fixed in 8e1c9b0"\n'
            "EOF"
        )
        self.assertIsNone(hook.unresolvable_sha(cmd, resolve=lambda repo, token: False))

    def test_command_without_a_repository_is_not_checked(self) -> None:
        """Without a target repo there is nothing to resolve the hash against."""
        self.assertIsNone(
            hook.unresolvable_sha(
                'gh pr comment 1 --body "fixed in 8e1c9b0"',
                resolve=lambda repo, token: False,
            )
        )


class UnresolvableShaOnGitLab(unittest.TestCase):
    """A glab body names a GitLab project; github.com cannot answer for it.

    As denied on 2026-11-28: a `glab mr note --repo group/project` body named a
    real commit of a self-hosted GitLab project. The gate asked
    `gh api repos/group/project/commits/<sha>`, github.com answered 404 for the
    unknown repository, and the gate called the hash invented.
    """

    BODY = 'glab mr note 1 --repo group/project -m "fixed in 8e1c9b0"'

    def setUp(self) -> None:
        self._saved = (hook._resolve_commit, hook._resolve_gitlab_commit)

    def tearDown(self) -> None:
        hook._resolve_commit, hook._resolve_gitlab_commit = self._saved

    def test_glab_body_is_resolved_on_gitlab(self) -> None:
        asked = []
        hook._resolve_commit = lambda repo, token: asked.append("github") or False
        hook._resolve_gitlab_commit = lambda repo, token: asked.append("gitlab") or True
        self.assertIsNone(hook.unresolvable_sha(self.BODY))
        self.assertEqual(["gitlab"], asked)

    def test_glab_body_with_unknown_hash_is_reported(self) -> None:
        hook._resolve_commit = lambda repo, token: True
        hook._resolve_gitlab_commit = lambda repo, token: False
        self.assertIn("8e1c9b0", hook.unresolvable_sha(self.BODY) or "")

    def test_gh_body_is_still_resolved_on_github(self) -> None:
        asked = []
        hook._resolve_commit = lambda repo, token: asked.append("github") or True
        hook._resolve_gitlab_commit = lambda repo, token: (
            asked.append("gitlab") or False
        )
        self.assertIsNone(
            hook.unresolvable_sha('gh pr comment 1 --repo o/r --body "in 8e1c9b0"')
        )
        self.assertEqual(["github"], asked)

    def test_glab_named_inside_a_gh_body_keeps_the_github_lookup(self) -> None:
        """The CLI that posts decides, not a command quoted in the body."""
        asked = []
        hook._resolve_commit = lambda repo, token: asked.append("github") or False
        hook._resolve_gitlab_commit = lambda repo, token: asked.append("gitlab") or None
        cmd = 'gh pr comment 1 --repo o/r --body "use glab mr note; fixed in 8e1c9b0"'
        self.assertIn("8e1c9b0", hook.unresolvable_sha(cmd) or "")
        self.assertEqual(["github"], asked)

    def test_glab_inside_a_shell_wrapper_is_resolved_on_gitlab(self) -> None:
        asked = []
        hook._resolve_commit = lambda repo, token: asked.append("github") or False
        hook._resolve_gitlab_commit = lambda repo, token: asked.append("gitlab") or True
        cmd = "bash -c 'glab mr note 1 --repo group/project -m \"fixed in 8e1c9b0\"'"
        self.assertIsNone(hook.unresolvable_sha(cmd))
        self.assertEqual(["gitlab"], asked)


class GitLabCommitLookup(unittest.TestCase):
    """How the glab answer maps to known, unknown and could-not-check."""

    def _run(self, rc: int, stderr: str):
        fake = subprocess.CompletedProcess(
            args=[], returncode=rc, stdout="", stderr=stderr
        )
        saved = hook.subprocess.run
        hook.subprocess.run = lambda *a, **k: fake
        try:
            return hook._resolve_gitlab_commit("group/project", "8e1c9b0")
        finally:
            hook.subprocess.run = saved

    def test_found(self) -> None:
        self.assertIs(True, self._run(0, ""))

    def test_unknown_commit(self) -> None:
        self.assertIs(False, self._run(1, "glab: 404 Commit Not Found (HTTP 404)"))

    def test_unknown_project_is_no_verdict(self) -> None:
        self.assertIsNone(self._run(1, "glab: 404 Project Not Found (HTTP 404)"))

    def test_auth_failure_is_no_verdict(self) -> None:
        self.assertIsNone(self._run(1, "glab: 401 Unauthorized (HTTP 401)"))


if __name__ == "__main__":
    unittest.main()
