#!/usr/bin/env python3
"""Unit tests for deploy-ai's scope guard, denylist, policy digest, and submission vetting.

They need no VM, no secrets, and no root: every guard takes its paths from the environment, so the
checks run against synthetic trees in a temp dir.  `nix flake check` runs them through the
package's `passthru.tests.scope`.
"""

import importlib.util
import io
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from contextlib import contextmanager, redirect_stderr
from pathlib import Path

HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("deploy_ai", HERE / "deploy-ai.py")
deploy_ai = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(deploy_ai)


def sh(argv: list[str], cwd: str | None = None) -> str:
    return subprocess.run(argv, cwd=cwd, capture_output=True, text=True, check=True).stdout


def commit(repo: str) -> str:
    sh(["git", "-C", repo, "add", "-A"])
    sh(["git", "-C", repo, "-c", "user.name=test", "-c", "user.email=test@localhost",
        "commit", "-q", "-m", "test"])
    return sh(["git", "-C", repo, "rev-parse", "HEAD"]).strip()


@contextmanager
def refusal():
    """A guard that refuses: `die` prints to stderr and exits 1, so the message is read there.

    The body must raise; falling through is itself a failed test.
    """
    captured = io.StringIO()
    with redirect_stderr(captured):
        try:
            yield captured
        except SystemExit as exit_request:
            if exit_request.code != 1:
                raise
        else:
            raise AssertionError("expected a refusal, got none")


@contextmanager
def patch_input(data: bytes):
    """`save_incoming_patch` reads stdin, which is what the forced command hands it."""
    previous = sys.stdin
    sys.stdin = io.TextIOWrapper(io.BytesIO(data))
    try:
        yield
    finally:
        sys.stdin = previous


class TempMixin(unittest.TestCase):
    """Every test gets its own state dir and policy files, so nothing reads `/etc/deploy-ai`."""

    def make_tool(self, **files: str) -> deploy_ai.DeployAI:
        root = tempfile.mkdtemp(prefix="deploy-ai-test.")
        self.addCleanup(shutil.rmtree, root, ignore_errors=True)
        state = os.path.join(root, "state")
        os.makedirs(state)
        env = {
            "DEPLOY_AI_STATE": state,
            "DEPLOY_AI_ALLOWLIST": os.path.join(root, "allowlist"),
            "DEPLOY_AI_DENY_FILE": os.path.join(root, "denylist"),
            "DEPLOY_AI_GUEST_ONLY_FILE": os.path.join(root, "guest-only-paths"),
            "DEPLOY_AI_POLICY_FILE": os.path.join(root, "policy-digest"),
            "DEPLOY_AI_SUBMIT_MAX_BYTES_FILE": os.path.join(root, "submit-max-bytes"),
            "DEPLOY_AI_BASELINE": os.path.join(root, "baseline"),
            "DEPLOY_AI_BASELINE_COMMIT": os.path.join(root, "deployed-commit"),
            "DEPLOY_AI_INBOX": os.path.join(state, "inbox"),
        }
        for name, content in files.items():
            Path(env[name]).write_text(content)
        os.makedirs(env["DEPLOY_AI_BASELINE"])
        self.root = root
        return deploy_ai.DeployAI(env)

    def sibling(self, name: str) -> str:
        """A temp path beside the tool's own files, so trees never nest inside each other."""
        path = os.path.join(self.root, name)
        os.makedirs(path, exist_ok=True)
        return path


class Matches(unittest.TestCase):
    def test_prefix_entry_matches_everything_under_it(self):
        self.assertTrue(deploy_ai.matches("platforms/buildvm.nix", ["platforms/"]))
        self.assertTrue(deploy_ai.matches("platforms/buildvm.nix", ["platforms/", "flake.lock"]))
        self.assertTrue(deploy_ai.matches("modules/nixos/x/y.nix", ["modules/"]))

    def test_bare_entry_matches_one_file(self):
        self.assertTrue(deploy_ai.matches("flake.lock", ["flake.lock"]))
        self.assertTrue(deploy_ai.matches("platforms/buildvm.nix", ["platforms/buildvm.nix"]))

    def test_near_misses_do_not_match(self):
        self.assertFalse(deploy_ai.matches("platformsx/buildvm.nix", ["platforms/"]))
        self.assertFalse(deploy_ai.matches("platforms/buildvm-other.nix", ["platforms/buildvm.nix"]))
        self.assertFalse(deploy_ai.matches("flake.nix", ["flake.lock"]))
        self.assertFalse(deploy_ai.matches("platforms/buildvm.nix", []))


class Scope(TempMixin):
    def test_changed_paths_are_repo_relative(self):
        tool = self.make_tool()
        Path(tool.baseline, "platforms").mkdir(parents=True)
        Path(tool.baseline, "flake.lock").write_text("lock\n")
        Path(tool.baseline, "platforms/buildvm.nix").write_text("one\n")
        work = self.sibling("work")
        os.makedirs(os.path.join(work, "platforms"))
        Path(work, "flake.lock").write_text("lock\n")
        Path(work, "platforms/buildvm.nix").write_text("two\n")
        Path(work, "platforms/new.nix").write_text("new\n")
        self.assertEqual(tool.changed_paths(work), ["platforms/buildvm.nix", "platforms/new.nix"])

    def test_a_reconstructed_tree_reports_no_git_plumbing(self):
        # The candidate carries a `.git` after `git init`; that is not a change the guard judges.
        tool = self.make_tool()
        Path(tool.baseline, "flake.lock").write_text("lock\n")
        work = self.sibling("work")
        Path(work, "flake.lock").write_text("lock\n")
        sh(["git", "-C", work, "init", "-q"])
        commit(work)
        self.assertEqual(tool.changed_paths(work), [])

    def test_out_of_scope_path_is_named_with_the_allowlist(self):
        tool = self.make_tool(DEPLOY_AI_ALLOWLIST="platforms/\n")
        candidate = self.sibling("candidate")
        Path(candidate, "modules/nixos").mkdir(parents=True)
        Path(candidate, "modules/nixos/x.nix").write_text("x\n")
        with refusal() as message:
            tool.check_scope(candidate)
        self.assertIn("modules/nixos/x.nix", message.getvalue())
        self.assertIn("outside the deploy-ai allowlist", message.getvalue())

    def test_baseline_commit_drops_the_dirty_suffix(self):
        sha = "0" * 40
        tool = self.make_tool()
        Path(tool.baseline_commit_file).write_text(sha + "\n")
        self.assertEqual(tool.baseline_commit(), sha)
        Path(tool.baseline_commit_file).write_text(sha + "-dirty\n")
        self.assertEqual(tool.baseline_commit(), sha)

    def test_missing_baseline_commit_is_a_refusal(self):
        tool = self.make_tool()
        with refusal() as message:
            tool.baseline_commit()
        self.assertIn("no baseline commit recorded", message.getvalue())

    def test_nearest_dir_names_the_allowlist_entries(self):
        tool = self.make_tool(DEPLOY_AI_ALLOWLIST="platforms/buildvm.nix\nmodules/nixos/\n")
        self.assertIn("platforms/buildvm.nix", tool.nearest_dir("platforms/ai.nix"))
        self.assertEqual(tool.nearest_dir("flake.nix"), "no top-level files are allowed")


class Denylist(TempMixin):
    def setUp(self):
        self.tool = self.make_tool(
            DEPLOY_AI_DENY_FILE="modules/nixos/deploy-ai/\npkgs/deploy-ai/\nflake.lock\n",
            DEPLOY_AI_ALLOWLIST="platforms/\nmodules/\npkgs/\nflake.lock\n")
        # The baseline holds the same lock file, so an unchanged candidate changes nothing.
        Path(self.tool.baseline, "flake.lock").write_text("lock\n")
        self.candidate = self.sibling("candidate")
        Path(self.candidate, "modules/nixos/deploy-ai").mkdir(parents=True)
        Path(self.candidate, "platforms").mkdir(parents=True)
        Path(self.candidate, "flake.lock").write_text("lock\n")
        Path(self.candidate, "platforms/buildvm.nix").write_text("ok\n")

    def test_denied_directory_is_named(self):
        Path(self.candidate, "modules/nixos/deploy-ai/default.nix").write_text("x\n")
        with refusal() as message:
            self.tool.check_deny(self.candidate)
        self.assertIn("is on the deploy-ai denylist", message.getvalue())
        self.assertIn("modules/nixos/deploy-ai/default.nix", message.getvalue())

    def test_denied_exact_file_is_named(self):
        Path(self.candidate, "flake.lock").write_text("changed\n")
        with refusal() as message:
            self.tool.check_deny(self.candidate)
        self.assertIn("flake.lock", message.getvalue())

    def test_allowed_tree_passes(self):
        self.assertIsNone(self.tool.check_deny(self.candidate))


class Policy(TempMixin):
    def setUp(self):
        self.tool = self.make_tool(DEPLOY_AI_POLICY_FILE="abc123\n",
                                   DEPLOY_AI_GUEST_ONLY_FILE="platforms/buildvm.nix\n",
                                   DEPLOY_AI_ALLOWLIST="platforms/\n")
        self.candidate = self.sibling("candidate")
        Path(self.candidate, "platforms").mkdir(parents=True)
        Path(self.candidate, "platforms/buildvm.nix").write_text("one\n")

    def test_all_guest_only_paths_classify_as_guest(self):
        self.assertEqual(self.tool.classify_changes(self.candidate), "guest")

    def test_one_host_path_classifies_as_ai(self):
        Path(self.candidate, "platforms/ai.nix").write_text("one\n")
        self.assertEqual(self.tool.classify_changes(self.candidate), "ai")

    def test_changed_policy_digest_is_refused(self):
        with refusal() as message:
            self.tool.check_policy("def456")
        self.assertIn("changes the deployment policy", message.getvalue())

    def test_matching_policy_digest_passes(self):
        self.assertIsNone(self.tool.check_policy("abc123"))


class Submission(TempMixin):
    def setUp(self):
        self.tool = self.make_tool(DEPLOY_AI_SUBMIT_MAX_BYTES_FILE="4096\n")
        self.baseline = self.tool.baseline
        Path(self.baseline, "platforms").mkdir(parents=True)
        Path(self.baseline, "flake.lock").write_text("lock\n")
        Path(self.baseline, "platforms/buildvm.nix").write_text("one\n")
        self.patch = os.path.join(self.root, "series.patch")

    def test_patch_is_staged_in_the_inbox(self):
        with patch_input(b"patch body\n"):
            saved = self.tool.save_incoming_patch()
        self.assertTrue(saved.startswith(self.tool.inbox))
        self.assertEqual(oct(os.stat(saved).st_mode & 0o777), "0o600")
        self.assertEqual(Path(saved).read_text(), "patch body\n")

    def test_oversized_patch_is_refused(self):
        with patch_input(b"x" * 5000):
            with refusal() as message:
                self.tool.save_incoming_patch()
        self.assertIn("patch too large", message.getvalue())

    def test_empty_patch_is_refused(self):
        with patch_input(b""):
            with refusal() as message:
                self.tool.save_incoming_patch()
        self.assertIn("empty patch on stdin", message.getvalue())

    def test_non_integer_cap_is_refused(self):
        Path(self.tool.submit_max_bytes_file).write_text("nope\n")
        self.tool.submit_max_bytes_raw = "nope"
        with patch_input(b"x\n"):
            with refusal() as message:
                self.tool.save_incoming_patch()
        self.assertIn("does not hold an integer", message.getvalue())

    def test_reconstruct_is_host_authored_and_carries_only_the_patch(self):
        # A series made against the baseline, exactly as `git format-patch` produces it.
        origin = os.path.join(self.root, "origin")
        shutil.copytree(self.baseline, origin)
        sh(["git", "-C", origin, "init", "-q"])
        commit(origin)
        Path(origin, "platforms/buildvm.nix").write_text("two\n")
        sha = commit(origin)
        Path(self.patch).write_text(
            sh(["git", "-C", origin, "format-patch", "--stdout", f"{sha}~1..{sha}"]))

        dest = self.sibling("dest")
        self.tool.reconstruct_tree(self.patch, dest, "deadbeef")
        self.assertEqual(self.tool.changed_paths(dest), ["platforms/buildvm.nix"])
        # One commit authored here, by the host, not by whatever identity the guest carries.
        self.assertEqual(sh(["git", "-C", dest, "rev-list", "--count", "HEAD"]).strip(), "1")
        self.assertEqual(sh(["git", "-C", dest, "log", "-1", "--format=%an"]).strip(), "deploy-ai")

    def test_stale_patch_is_refused(self):
        Path(self.patch).write_text(
            "From 0000000000000000000000000000000000000000 Mon Sep 17 00:00:00 2001\n"
            "Subject: [PATCH] change\n\n"
            "--- a/platforms/buildvm.nix\n"
            "+++ b/platforms/buildvm.nix\n"
            "@@\n"
            "-never-there\n"
            "+whatever\n")
        dest = self.sibling("dest")
        with refusal() as message:
            self.tool.reconstruct_tree(self.patch, dest, "deadbeef")
        self.assertIn("rebase it onto deadbeef", message.getvalue())


class Usage(unittest.TestCase):
    def test_unknown_flag_exits_one(self):
        with self.assertRaises(SystemExit) as caught:
            deploy_ai.parse_args(["--frobnicate"])
        self.assertEqual(caught.exception.code, 1)

    def test_help_exits_zero(self):
        with self.assertRaises(SystemExit) as caught:
            deploy_ai.parse_args(["--help"])
        self.assertEqual(caught.exception.code, 0)

    def test_known_flags_parse(self):
        self.assertTrue(deploy_ai.parse_args(["--vet"]).vet)
        self.assertTrue(deploy_ai.parse_args(["--submit"]).submit)


class Root(unittest.TestCase):
    def test_non_root_is_refused(self):
        tool = deploy_ai.DeployAI()
        if os.geteuid() == 0:
            self.skipTest("running as root")
        with refusal() as message:
            tool.need()
        self.assertIn("must run as root", message.getvalue())


if __name__ == "__main__":
    unittest.main()
