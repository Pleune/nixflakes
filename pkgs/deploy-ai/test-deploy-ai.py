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
import types
import sys
import tempfile
import unittest
from datetime import datetime, timezone
from contextlib import contextmanager, redirect_stderr, redirect_stdout
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


class Result:
    """Stand-in for a subprocess result, so a test can stub a probe without a system."""

    def __init__(self, returncode=0, stdout="", stderr=""):
        self.returncode = returncode
        self.stdout = stdout
        self.stderr = stderr


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
            "DEPLOY_AI_HEALTH_UNITS": os.path.join(root, "health-units"),
            "DEPLOY_AI_HEALTH_URL": os.path.join(root, "health-url"),
        }
        # A host publishes what it considers healthy, so the tests start from a configured probe
        # (the gateway's real path) and override it when a case wants a broken one.
        Path(env["DEPLOY_AI_HEALTH_UNITS"]).write_text(
            "hermes-agent\nhermes-backend\nhermes-webui\n")
        Path(env["DEPLOY_AI_HEALTH_URL"]).write_text("http://127.0.0.1:8642/health\n")
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


class GuestLogin(TempMixin):
    """Who deploy-ai logs into the VM as, with which key, and what a bad key says.

    Every check here stands for a deploy that used to fail with no message: ssh wrote its reason to
    stderr, and nothing read stderr.
    """

    def tool_with_key(self) -> deploy_ai.DeployAI:
        tool = self.make_tool()
        key = os.path.join(self.root, "id_ed25519")
        Path(key).write_text("key\n")
        tool.build_key = key
        tool.guest_root_key = key
        return tool

    def test_the_two_users_are_two_logins_on_one_forward(self):
        tool = self.tool_with_key()
        builder = tool.guest_ssh_argv("builder", "true")
        root = tool.guest_ssh_argv("root", "true")
        self.assertEqual(builder[builder.index("-i") + 1], tool.build_key)
        self.assertEqual(root[root.index("-i") + 1], tool.guest_root_key)
        self.assertIn("builder@127.0.0.1", builder)
        self.assertIn("root@127.0.0.1", root)
        self.assertEqual(builder[builder.index("-p") + 1], "2224")
        self.assertEqual(builder[-1], "true")

    def test_a_reseeded_guest_is_not_a_host_key_refusal(self):
        # buildvm-install replaces the guest's sshd host keys whenever the disk is re-seeded.
        tool = self.tool_with_key()
        for argv in (tool.guest_ssh_argv("builder", "true"), tool.guest_ssh_argv("root", "true")):
            self.assertIn("UserKnownHostsFile=/dev/null", argv)
            self.assertIn("StrictHostKeyChecking=accept-new", argv)
            self.assertIn("BatchMode=yes", argv)

    def test_an_unreadable_key_names_the_file_and_the_user(self):
        tool = self.tool_with_key()
        tool.build_key = os.path.join(self.root, "missing")
        with refusal() as message:
            tool.guest_ssh_argv("builder", "true")
        self.assertIn("missing", message.getvalue())
        self.assertIn("builder", message.getvalue())

    def test_one_keypair_serves_both_users_when_root_publishes_none(self):
        # What ai does: /etc/deploy-ai/guest-root-key and /etc/deploy-ai/build-key name one file.
        tool = self.make_tool()
        key = os.path.join(self.root, "id_ed25519")
        Path(key).write_text("key\n")
        probe = deploy_ai.DeployAI({
            "DEPLOY_AI_STATE": tool.state,
            "DEPLOY_AI_BUILD_KEY": key,
            "DEPLOY_AI_GUEST_ROOT_KEY_FILE": os.path.join(self.root, "absent"),
        })
        self.assertEqual(probe.guest_root_key, key)

    def test_a_repo_on_the_vm_refuses_before_a_fetch_it_cannot_make(self):
        # The VM mirror is reachable only as `builder`, so a missing key is a configuration refusal.
        tool = self.make_tool()
        tool.build_key = os.path.join(self.root, "missing")
        tool.repo = "ssh://builder@127.0.0.1:2224/home/builder/nixflakes"
        calls = []

        def run(argv, **kwargs):
            calls.append(argv)
            return Result(stdout="", stderr="")

        tool.run = run
        with refusal() as message:
            tool.ensure_mirror()
        self.assertIn("missing", message.getvalue())
        self.assertFalse([argv for argv in calls if "fetch" in argv])

    def test_the_mirror_path_is_not_the_method_that_fills_it(self):
        # `self.mirror` names the bare repo; the method that creates and fetches it must not share
        # that name, or every `--repo/--ref` deploy calls a string.
        tool = self.make_tool()
        self.assertFalse(callable(tool.mirror))
        self.assertTrue(callable(tool.ensure_mirror))
        fetched = []

        def run(argv, **kwargs):
            fetched.append(argv)
            return Result(stdout="", stderr="")

        tool.run = run
        tool.repo = "ssh://git@host.example/mitch/repo.git"
        tool.ensure_mirror()
        self.assertTrue([argv for argv in fetched if "fetch" in argv])

    def test_a_git_host_fetch_still_uses_whatever_root_holds(self):
        tool = self.make_tool()
        tool.build_key = os.path.join(self.root, "missing")
        tool.repo = "ssh://git@host.example/mitch/repo.git"
        self.assertTrue(tool.ssh_command().startswith("ssh -o"))

    def test_the_guest_marker_survives_a_guest_that_drops_builder(self):
        tool = self.tool_with_key()
        written = []
        tool.guest_root_ssh = lambda command: written.append(command) or Result()
        tool.vm_ssh = lambda command: self.fail("the marker must not depend on builder")
        tool.record_in_guest("a" * 40)
        self.assertEqual(len(written), 1)
        self.assertIn(tool.recorded_commit, written[0])
        self.assertIn("a" * 40, written[0])


class SeriesTip(TempMixin):
    def test_the_newest_from_header_is_the_tip(self):
        tool = self.make_tool()
        patch = os.path.join(self.root, "series.patch")
        Path(patch).write_text(
            "From " + "1" * 40 + " Mon Jan 1 00:00:00 2026\nFrom \n"
            + "From " + "2" * 40 + " Mon Jan 1 00:00:00 2026\n")
        self.assertEqual(tool.series_tip(patch), "2" * 40)

    def test_a_series_without_headers_has_no_tip(self):
        tool = self.make_tool()
        patch = os.path.join(self.root, "bare.patch")
        Path(patch).write_text("diff --git a/x b/x\n")
        self.assertEqual(tool.series_tip(patch), "")
        self.assertEqual(tool.series_tip(os.path.join(self.root, "absent")), "")


class RetainedBase(TempMixin):
    def test_the_reconstructed_commit_stays_resolvable(self):
        # A gate deploy's commit exists nowhere else, so `--status` and the next diff baseline need
        # the bare copy retain_base keeps.
        tool = self.make_tool()
        tree = self.sibling("tree")
        Path(tree, "flake.nix").write_text("{}\n")
        sh(["git", "-C", tree, "init", "-q"])
        sha = commit(tree)
        tool.retain_base(tree)
        base = os.path.join(tool.state, "base.git")
        self.assertEqual(sh(["git", "--git-dir", base, "rev-parse", "HEAD"]).strip(), sha)


class Output(TempMixin):
    """What the agent reads back.  A verdict that needs parsing is a verdict that gets misread.

    The probes are stubbed: these tests have no systemd, no curl, and no VM, and must still show the
    rows a switcher depends on.
    """

    def rows(self, tool, command: str) -> str:
        captured = io.StringIO()
        with redirect_stdout(captured):
            getattr(tool, command)()
        return captured.getvalue()

    @staticmethod
    def row(label: str, value: str) -> str:
        """The same shape `say` prints, so a test asserts on content rather than on spacing."""
        return f"  {label:<9} {value}"

    def test_a_commit_prints_short_but_records_full(self):
        self.assertEqual(deploy_ai.short("d" * 40), "d" * 10)
        self.assertEqual(deploy_ai.short("abc"), "abc")
        self.assertEqual(deploy_ai.short(""), "none")

    def test_a_size_reads_at_a_glance(self):
        self.assertEqual(deploy_ai.hum(512), "512B")
        self.assertEqual(deploy_ai.hum(2048), "2.0K")

    def test_a_refusal_and_a_failure_close_with_their_own_word(self):
        with refusal() as message:
            deploy_ai.die("no")
        self.assertIn("refusing: no", message.getvalue())
        self.assertIn("result: refused", message.getvalue())
        captured = io.StringIO()
        with self.assertRaises(SystemExit), redirect_stderr(captured):
            deploy_ai.fail("the build broke")
        self.assertIn("failed: the build broke", captured.getvalue())
        self.assertIn("result: failed", captured.getvalue())

    def test_status_answers_what_is_live_and_whether_it_is_healthy(self):
        tool = self.make_tool(DEPLOY_AI_POLICY_FILE="3" * 64 + "\n")
        Path(tool.state, "commit").write_text("f" * 40 + "\n")
        Path(tool.state, "toplevel").write_text("/nix/store/x-nixos-system-ai\n")
        Path(tool.state, "refs.log").write_text(
            "2026-11-19T20:00:00\t" + "a" * 40 + "\tsubmit\n")
        tool.run = lambda argv, **kwargs: Result(
            stdout="200\n" if argv[0] == "curl" else "NextElapseSince1970Usec=infinity\n")
        tool.vm_ssh = lambda command: Result(stdout="b" * 40 + "\n")
        text = self.rows(tool, "do_status")
        self.assertIn(self.row("commit", "f" * 10), text)
        self.assertIn(self.row("health", "ok"), text)
        self.assertIn(self.row("guest", "b" * 10), text)
        self.assertIn(self.row("last", f"2026-11-19T20:00:00  {'a' * 10}  submit"), text)
        self.assertIn(self.row("policy", "locked; a patch cannot change it"), text)
        self.assertNotIn("3" * 10, text)
        self.assertIn(self.row("guard", "none armed"), text)

    def test_status_says_which_service_is_down(self):
        tool = self.make_tool()

        def probe(argv, **kwargs):
            # One service down, and the health endpoint answering nothing at all, which is what a
            # switch would treat as an unhealthy system.
            return Result(returncode=1 if argv[-1] == "hermes-webui" or "curl" in argv[0] else 0)

        tool.run = probe
        tool.vm_ssh = lambda command: Result(returncode=255, stderr="Permission denied (publickey)")
        text = self.rows(tool, "do_status")
        self.assertIn(self.row("health",
                              "down: hermes-webui inactive, health endpoint answered nothing"), text)
        self.assertIn(self.row("guest",
                              "unknown, ssh to the VM failed: Permission denied (publickey)"), text)

    def test_status_reports_the_reboot_the_guard_armed(self):
        tool = self.make_tool()
        stamp = datetime(2026, 11, 19, 21, 30, tzinfo=timezone.utc)
        usec = int(stamp.timestamp() * 1_000_000)
        tool.run = lambda argv, **kwargs: Result(
            stdout=f"NextElapseSince1970Usec={usec}\n")
        armed = datetime.fromtimestamp(usec / 1_000_000).astimezone().isoformat(timespec="minutes")
        self.assertEqual(tool.guard_row(), f"reboot armed at {armed}")
        tool.run = lambda argv, **kwargs: Result(stdout="NextElapseSince1970Usec=infinity\n")
        self.assertEqual(tool.guard_row(), "none armed")

    def test_an_unreachable_state_leaves_no_mystery(self):
        tool = self.make_tool()
        self.assertEqual(tool.last_row(), "none recorded")


class Health(TempMixin):
    """The switch is gated on a probe that has to describe this host.  A wrong endpoint used to read
    exactly like a dead service, so a healthy machine refused every deploy."""

    def answer(self, tool, stdout="200\n", returncode=0):
        """Stub the probes so only the health endpoint's answer varies."""
        tool.run = lambda argv, **kwargs: (
            Result(stdout=stdout, returncode=returncode) if argv[0] == "curl" else Result())

    def test_the_url_probed_is_the_one_the_host_published(self):
        tool = self.make_tool(DEPLOY_AI_HEALTH_URL="http://127.0.0.1:9999/health\n")
        asked = []

        def probe(argv, **kwargs):
            asked.append(argv)
            return Result(stdout="200\n") if argv[0] == "curl" else Result()

        tool.run = probe
        self.assertEqual(tool.health_problems(), [])
        self.assertEqual(asked[-1][-1], "http://127.0.0.1:9999/health")

    def test_a_wrong_path_names_the_status_code_not_a_dead_service(self):
        tool = self.make_tool()
        self.answer(tool, stdout="404\n")
        self.assertEqual(tool.health_problems(), ["health endpoint answered 404"])

    def test_nothing_listening_is_not_reported_as_a_status_code(self):
        tool = self.make_tool()
        self.answer(tool, returncode=7)
        self.assertEqual(tool.health_problems(), ["health endpoint answered nothing"])

    def test_a_missing_probe_is_said_out_loud_instead_of_guessed(self):
        tool = self.make_tool(DEPLOY_AI_HEALTH_URL="\n")
        self.answer(tool)
        self.assertEqual(tool.health_problems(), ["no health endpoint configured"])

    def test_a_inactive_unit_names_that_unit(self):
        tool = self.make_tool()
        self.answer(tool)
        tool.run = lambda argv, **kwargs: (
            Result(returncode=1) if argv[-1] == "hermes-backend"
            else Result(stdout="200\n") if argv[0] == "curl" else Result())
        self.assertEqual(tool.health_problems(), ["hermes-backend inactive"])

    def test_a_healthy_system_opens_the_switch(self):
        tool = self.make_tool()
        self.answer(tool)
        tool.vm_ssh = lambda command: Result(stdout="ok\n")
        self.assertTrue(tool.check_health())


class DryRun(TempMixin):
    """A dry run reports what it would do.  A record says something is live, so writing one here would
    make `--status` describe a deploy that never happened."""

    def test_a_dry_run_leaves_no_claim_about_what_is_live(self):
        tool = self.make_tool()
        tool.dry_run = True
        tool.toplevel = "/nix/store/fake-toplevel"
        seen = []
        tool.record_rollback = lambda previous: seen.append("rollback recorded")
        tool.check_health = lambda: True
        tool.arm_guard = lambda: seen.append("armed")
        tool.do_switch = lambda: seen.append("switched")
        tool.wait_health = lambda: self.fail("a dry run must not probe health")
        tool.record_in_guest = lambda sha: self.fail("a dry run must not tell the VM anything")
        with redirect_stdout(io.StringIO()):
            tool.switch_with_guards("a" * 40, lambda sha: self.fail("a dry run must not record a deploy"))
        self.assertEqual(seen, ["rollback recorded", "armed", "switched"])
        for name in ("commit", "toplevel", "refs.log"):
            self.assertFalse(os.path.exists(os.path.join(tool.state, name)), name)


class Structure(unittest.TestCase):
    """Names inside DeployAI must not collide: an attribute that shares a method's name turns a
    call into a TypeError, which is how `--repo/--ref` used to fail."""

    def test_no_instance_attribute_shadows_a_method(self):
        tool = deploy_ai.DeployAI()
        methods = {name for name, value in vars(deploy_ai.DeployAI).items()
                   if isinstance(value, (types.FunctionType, types.MethodType))}
        self.assertEqual(sorted(methods & set(vars(tool))), [])


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
