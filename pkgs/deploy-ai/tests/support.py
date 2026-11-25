"""Shared harness for deploy-ai's scenario tests.

The tool reads every guard path from the environment, so tests need no VM, no secrets, and no
root: they run against synthetic trees in a temp dir.  ``conftest.py`` puts this directory on
``sys.path``; ``HERE`` is the package dir that holds ``deploy-ai.py``.

``World`` is the scenario harness: real git and tar run for real (a scenario really fetches,
archives, diffs, and reconstructs), while nix/ssh/curl/systemctl/systemd-run are answered by one
dispatcher that records every argv it saw in ``world.calls``.  Control knobs say what the machine
answers, and the boot machinery is simulated with real files: generations are directories with a
``bin/switch-to-configuration``, loader entries name them, and a switch moves ``world.running``.
A scenario therefore drives a whole public verb and asserts state transitions plus the argv
contract, not per-method stub bookkeeping.
"""

import importlib.util
import io
import os
import shutil
import subprocess
import sys
import tempfile
import time
from contextlib import contextmanager, redirect_stderr, redirect_stdout
from pathlib import Path

HERE = Path(__file__).resolve().parent.parent
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
def outcome():
    """A step that failed after the guards passed: `fail` prints `result: failed` and exits 1."""
    captured = io.StringIO()
    with redirect_stderr(captured):
        try:
            yield captured
        except SystemExit as exit_request:
            if exit_request.code != 1:
                raise
        else:
            raise AssertionError("expected a failure, got none")


@contextmanager
def patch_input(data: bytes):
    """`save_incoming_patch` reads stdin, which is what the forced command hands it."""
    previous = sys.stdin
    sys.stdin = io.TextIOWrapper(io.BytesIO(data))
    try:
        yield
    finally:
        sys.stdin = previous


def captured(fn) -> str:
    """What a reporting verb prints to stdout."""
    out = io.StringIO()
    with redirect_stdout(out):
        fn()
    return out.getvalue()


def row(label: str, value: str) -> str:
    """The same shape `say` prints, so tests assert content rather than spacing."""
    return f"  {label:<9} {value}"


class Result:
    """Stand-in for a subprocess result, so the dispatcher can answer without a system."""

    def __init__(self, returncode=0, stdout="", stderr=""):
        self.returncode = returncode
        self.stdout = stdout
        self.stderr = stderr


class TempBase:
    """Every test gets its own state dir and policy files, so nothing reads `/etc/deploy-ai`."""

    def setup_method(self):
        self._cleanup = []
        self._saved_wrapper = deploy_ai.GATE_WRAPPER
        # The switch unit re-enters through the system wrapper; tests have no profile, so point
        # the wrapper at this interpreter -- anything executable stands in for the installed gate.
        deploy_ai.GATE_WRAPPER = sys.executable

    def teardown_method(self):
        for undo in reversed(self._cleanup):
            undo()
        if getattr(self, "root", None):
            shutil.rmtree(self.root, ignore_errors=True)
        deploy_ai.GATE_WRAPPER = self._saved_wrapper

    def make_tool(self, **files: str) -> deploy_ai.DeployAI:
        root = tempfile.mkdtemp(prefix="deploy-ai-test.")
        self._cleanup.append(lambda: shutil.rmtree(root, ignore_errors=True))
        state = os.path.join(root, "state")
        os.makedirs(state)
        env = {
            "DEPLOY_AI_STATE": state,
            "DEPLOY_AI_ALLOWLIST": os.path.join(root, "allowlist"),
            "DEPLOY_AI_DENY_FILE": os.path.join(root, "denylist"),
            "DEPLOY_AI_MAX_JOBS": os.path.join(root, "build-max-jobs"),
            "DEPLOY_AI_POLICY_FILE": os.path.join(root, "policy-digest"),
            "DEPLOY_AI_SUBMIT_MAX_BYTES_FILE": os.path.join(root, "submit-max-bytes"),
            "DEPLOY_AI_BASELINE": os.path.join(root, "baseline"),
            "DEPLOY_AI_BASELINE_COMMIT": os.path.join(root, "deployed-commit"),
            "DEPLOY_AI_INBOX": os.path.join(state, "inbox"),
            "DEPLOY_AI_BUILD_KEY": os.path.join(root, "build-key"),
            "DEPLOY_AI_HEALTH_UNITS": os.path.join(root, "health-units"),
            "DEPLOY_AI_HEALTH_URL": os.path.join(root, "health-url"),
            "DEPLOY_AI_TRUSTED_SOURCES": os.path.join(root, "trusted-sources"),
            # A fake ESP: the boot pin is the rollback, so tests need a loader.conf and entries
            # to pin and read.  `nixos-old` is the entry that boots the running toplevel.
            "DEPLOY_AI_BOOT_CONF": os.path.join(root, "loader.conf"),
            "DEPLOY_AI_BOOT_ENTRIES": os.path.join(root, "entries"),
            "DEPLOY_AI_SYSTEM_PROFILE": os.path.join(root, "system-profile"),
        }
        Path(env["DEPLOY_AI_BOOT_CONF"]).write_text("timeout 5\ndefault nixos-*\n")
        entries = env["DEPLOY_AI_BOOT_ENTRIES"]
        os.makedirs(entries)
        for gen in ("old", "new"):
            Path(os.path.join(entries, f"nixos-{gen}.conf")).write_text(
                f"title NixOS\noptions init=/nix/store/{gen}/init\n")
        # A host publishes what it considers healthy, so the tests start from a configured probe
        # (the gateway's real path) and override it when a case wants a broken one.
        Path(env["DEPLOY_AI_HEALTH_UNITS"]).write_text(
            "hermes-agent\nhermes-backend\nhermes-webui\n")
        Path(env["DEPLOY_AI_HEALTH_URL"]).write_text("http://127.0.0.1:8642/health\n")
        # A key that exists, so probes are about what the VM answers rather than a file no test
        # created; the case that wants a missing key removes it.
        Path(env["DEPLOY_AI_BUILD_KEY"]).write_text("not a real key\n")
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


class World(TempBase):
    """The whole host simulated in one temp tree; scenarios drive real verbs through it."""

    TOPLEVEL = "/nix/store/new-system"  # what the fake `nix build` prints

    def setup_method(self, **files) -> deploy_ai.DeployAI:
        super().setup_method()
        self.tool = self.make_tool(**files)
        self.calls: list[str] = []
        self.build_calls: list[tuple[str, list[str]]] = []  # (tree, listing) at build time
        self.healthy = True           # what the units and the endpoint answer right now
        self.after_switch_healthy = True
        self.ssh_rc = 0
        self.ssh_out = "ok\n"
        self.curl_code = "200"        # "" -> nothing configured; "none" -> nothing listening
        self.build_rc = 0
        self.policy = "abc123"        # the digest `nix eval` reports from the candidate tree
        self.guard = "infinity"       # what `systemctl show` reports (empty of a schedule: logind's
        # schedule file is the truth; `reboot --when` writes it and `cancel --when` removes it).
        self.schedule_path = os.path.join(self.root, "shutdown-scheduled")
        self.tool.shutdown_schedule = self.schedule_path
        self.cancel_failures = 0      # cancel attempts to fail first (a mid-switch logind restart)
        self.switch_rc = 0
        self.rollback_rc = 0
        self.boot_installs = True     # whether `switch-to-configuration boot` leaves an entry
        self.tail_rc = 0              # what systemd-run reports for the transient unit
        # Generations are real directories: rollback reaches for the switcher by path.
        self.gen_old = self.sibling("gen-old")
        os.makedirs(os.path.join(self.gen_old, "bin"))
        switcher = os.path.join(self.gen_old, "bin", "switch-to-configuration")
        Path(switcher).write_text("#!/bin/sh\nexit 0\n")
        os.chmod(switcher, 0o755)
        self.running = self.gen_old
        Path(self.tool.boot_entries, "nixos-old.conf").write_text(
            f"title NixOS\noptions init={self.gen_old}/init\n")
        self._saved_sleep = deploy_ai.time.sleep
        deploy_ai.time.sleep = lambda _seconds: None  # the health-retry loop runs at test speed
        self._saved_euid = deploy_ai.os.geteuid
        deploy_ai.os.geteuid = lambda: 0              # the gate demands root
        self.tool.current_system = lambda: self.running
        self.tool.run = self.dispatch
        return self.tool

    def teardown_method(self):
        deploy_ai.time.sleep = self._saved_sleep
        deploy_ai.os.geteuid = self._saved_euid
        super().teardown_method()

    def saw(self, needle: str) -> bool:
        """Whether the machine was asked to run something containing `needle`."""
        return any(needle in call for call in self.calls)

    @property
    def profile_links(self) -> list[str]:
        """The toplevels linked as system generation profiles, oldest generation first."""
        profile_dir = os.path.dirname(self.tool.system_profile)
        prefix = os.path.basename(self.tool.system_profile) + "-"
        generations = {}
        for name in os.listdir(profile_dir):
            if name.startswith(prefix) and name.endswith("-link"):
                generations[int(name[len(prefix) : -len("-link")])] = os.path.realpath(
                    os.path.join(profile_dir, name))
        return [generations[g] for g in sorted(generations)]

    def dispatch(self, argv, **kwargs):
        self.calls.append(" ".join(argv))
        cmd = argv[0]
        if cmd == "nix":
            if argv[1] == "build":
                tree = argv[-1].split("#", 1)[0]
                self.build_calls.append((tree, sorted(os.listdir(tree))))
                if self.build_rc != 0:
                    return Result(self.build_rc, "", "error: cannot build\n")
                return Result(stdout=self.TOPLEVEL + "\n")
            if argv[1] == "eval":
                if argv[-1].endswith(".policyDigest"):
                    return Result(stdout=self.policy + "\n")
                return Result(stdout=self.TOPLEVEL + "\n")  # outPath agrees with the build
        elif cmd == "ssh":
            return Result(self.ssh_rc, self.ssh_out, "ssh: connect refused")
        elif cmd == "curl":
            return Result(0 if self.curl_code else 7, self.curl_code or "")
        elif cmd == "systemctl":
            if argv[1] == "is-active":
                return Result(0 if self.healthy else 1)
            if argv[1] == "show" and argv[2] == "reboot":
                return Result(stdout=f"NextElapseSince1970Usec={self.guard}\n")
            if argv[1] == "reboot":
                # The timed reboot arms: logind writes the schedule file.
                Path(self.schedule_path).write_text(
                    f"USEC={int(time.time() * 1_000_000) + 3_600_000_000}\nMODE=reboot\n")
                return Result()               # the timed reboot arms
            if argv[1] == "cancel":
                if self.cancel_failures > 0:
                    self.cancel_failures -= 1
                    return Result(1, "", "Failed to cancel scheduled shutdown: Bus not open\n")
                try:
                    os.unlink(self.schedule_path)
                except FileNotFoundError:
                    pass
                return Result()               # `cancel --when` and friends succeed
        elif cmd == "systemd-run":
            # The transient unit re-enters the tail exactly as systemd would exec it, and a tail
            # that exits takes the unit's exit code with it.
            sha = argv[argv.index("--sha") + 1]
            if self.tail_rc != 0:
                return Result(self.tail_rc)
            try:
                self.tool.switch_tail(sha)
            except SystemExit as exit_request:
                return Result(exit_request.code if isinstance(exit_request.code, int) else 1)
            return Result()
        elif cmd == "journalctl":
            return Result()
        elif cmd.endswith("bin/switch-to-configuration"):
            if argv[0] == os.path.join(self.gen_old, "bin", "switch-to-configuration"):
                if argv[1] == "boot":  # install the entry naming the old generation
                    if self.boot_installs:
                        Path(self.tool.boot_entries, "nixos-old.conf").write_text(
                            f"title NixOS\noptions init={self.gen_old}/init\n")
                    return Result()
                self.running = self.gen_old  # the rollback switched back for real
                return Result(self.rollback_rc)
            toplevel = os.path.dirname(os.path.dirname(cmd))
            if argv[1] == "boot":  # install the loader entry for the toplevel being activated
                if self.boot_installs:
                    Path(self.tool.boot_entries, "nixos-new.conf").write_text(
                        f"title NixOS\noptions init={toplevel}/init\n")
                return Result()
            self.running = toplevel
            self.healthy = self.after_switch_healthy
            return Result(self.switch_rc)
        return deploy_ai.DeployAI.run(self.tool, argv, **kwargs)  # git/tar really run


class DeployWorld(World):
    """A World plus a real repository carrying the deployed commit, and a recorded deploy of it."""

    def setup_method(self, **files):
        super().setup_method(**files)

    def origin(self, **files: str) -> tuple[str, str]:
        """A git repo as the deployed tree, with `self.tool.baseline` holding exactly that tree."""
        repo = self.sibling("origin")
        for name, content in files.items():
            path = Path(os.path.join(repo, name))
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content)
        sh(["git", "-C", repo, "-c", "init.defaultBranch=main", "init", "-q"])
        deployed = commit(repo)
        dest = self.sibling("baseline-copy")
        self.tool.baseline = dest
        subprocess.run(["git", "-C", repo, "archive", "--format=tar", deployed], check=True,
                       stdout=open(os.path.join(self.root, "t.tar"), "wb"))
        sh(["tar", "x", "-C", dest, "-f", os.path.join(self.root, "t.tar")])
        # What is live: the gate's records claim the deployed commit on the old generation.
        Path(self.tool.state, "commit").write_text(deployed + "\n")
        Path(self.tool.state, "toplevel").write_text(self.gen_old + "\n")
        Path(self.tool.baseline_commit_file).write_text(deployed + "\n")
        return repo, deployed

    def revise(self, repo: str, **files: str) -> str:
        """A new commit on `main` -- the shape of a real upstream change to deploy."""
        for name, content in files.items():
            path = Path(os.path.join(repo, name))
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content)
        return commit(repo)
