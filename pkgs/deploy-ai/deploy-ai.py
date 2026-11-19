#!/usr/bin/env python3
"""deploy-ai — the only way anything changes ai's system.

Runs as root, normally through the forced-command account `deployer`, which the build VM's key is
authorized for.

Guards, in order: the deployed commit must be an ancestor of `--ref`, and the tree diff against the
source of the running system must stay inside `nixflakes.deploy-ai.allowlist` (plus its denylist and
the policy digest, for a submitted patch).  After the switch a failed health probe rolls back,
backed by a timed reboot guard.

The flake is built inside the build VM (qemu on this host) and its store closure copied back with
`nix-copy-closure`.  No repo lives on ai, so `--repo` names one on every call that fetches, and
`--submit` rebuilds the tree from ai's own recorded baseline instead of trusting the guest.

Why Python rather than shell: the guards below are the security boundary, and their failure modes
were shell failure modes — `set -e` interacting with a loop's exit status, one `trap` replacing
another and leaking the lock directory, quoting inside a remote command string.  Every value still
reaches `git`/`ssh`/`nix`/`tar` as an argv list, so no shell parses any of them.
"""

import argparse
import datetime
import os
import shlex
import shutil
import subprocess
import sys
import tempfile
import time

UMASK = 0o022
AI = "ai"
BUILD_HOST = "127.0.0.1"
BUILD_PORT = "2224"
BUILDER = "builder"
BUILD_TIMEOUT = 3600
EVAL_TIMEOUT = 600
HEALTH_RETRIES = 24
HEALTH_WAIT = 5
API = "http://127.0.0.1:8642/api/v1/health"
UNITS = ["hermes-agent", "hermes-backend", "hermes-webui"]
GUARD_MINUTES = 60
DEFAULT_SUBMIT_MAX_BYTES = 262144

# Paths `changed_paths()` ignores: VCS and harness droppings, plus the secrets checkout, which is
# never part of the flake source and must not appear in a refusal.
DIFF_EXCLUDES = [
    ".git",
    ".direnv",
    ".ralph",
    "result",
    "state.json",
    "secrets",
    "nix-support",
]

USAGE = """deploy-ai: build and switch ai from a commit in a git repository.

  deploy-ai --repo <url> --ref <rev>     build <rev> on the VM and switch ai to it
  deploy-ai --repo <url> --ref <rev> --dry-run
  deploy-ai --repo <url> --list          refs visible in that repository
  deploy-ai --status                     what is deployed now, and why
  deploy-ai --submit                     vet a patch series on stdin and provision it immediately
  deploy-ai --vet                        the same checks, nothing applied; prints the verdict
  deploy-ai --submit --dry-run           vet and report, apply nothing

<url> is any git URL root can read: the git host, or a repository on the VM
(ssh://builder@127.0.0.1:2224/home/builder/nixflakes).  --repo is required for anything
that fetches.

  --local     build on ai instead of the VM, for an operator who wants that

--submit/--vet read a series from stdin, e.g.

  git format-patch --stdout deployed..main | ssh deployer@10.0.2.2 'deploy-ai --submit'

The patch is applied to the source of the running system, never to a tree the guest supplies.
A submission that changes only build-VM paths switches the build VM; anything else goes through
the switch path above, with the same rollback and health guards.
"""


def die(message: str) -> "NoReturn":
    print(f"deploy-ai: refusing: {message}", file=sys.stderr)
    raise SystemExit(1)


def read_first_line(path: str) -> str:
    """First line of a file, '' when it is unreadable — the way `head -n 1` behaved under `[ -r ]`."""
    try:
        with open(path, encoding="utf-8", errors="replace") as handle:
            return handle.readline().strip()
    except OSError:
        return ""


def path_list_file(path: str) -> list[str]:
    """Entries of a `/etc/deploy-ai/*` list file: blank and `#` lines are comments."""
    try:
        with open(path, encoding="utf-8", errors="replace") as handle:
            return [
                line.split()[0]
                for line in handle
                if line.split() and not line.lstrip().startswith("#")
            ]
    except OSError:
        return []


def matches(path: str, entries: list[str]) -> bool:
    """A prefix entry ends in `/` and matches everything under it; a bare entry names one file.

    Deliberately literal: `platforms/` must not match `platformsx/`, and `flake.nix` must not match
    `flake.nix.tmp`.
    """
    for entry in entries:
        if entry.endswith("/"):
            if path.startswith(entry):
                return True
        elif path == entry:
            return True
    return False


class DeployAI:
    """One invocation.  Every path is overridable so the unit tests can exercise the guards as an
    unprivileged user; the defaults are what the NixOS module installs."""

    def __init__(self, env=None):
        env = os.environ if env is None else env
        get = env.get

        self.state = get("DEPLOY_AI_STATE", "/var/lib/deploy-ai")
        self.allowlist_file = get("DEPLOY_AI_ALLOWLIST", "/etc/deploy-ai/allowlist")
        self.mirror = os.path.join(self.state, "repo")

        self.baseline_file = get("DEPLOY_AI_BASELINE_FILE", "/etc/deploy-ai/deployed-source")
        self.baseline_commit_file = get("DEPLOY_AI_BASELINE_COMMIT", "/etc/deploy-ai/deployed-commit")
        # A recorded baseline is a store path copied into /etc by the module; the first line of that
        # file names the source it was built from.
        self.baseline = get("DEPLOY_AI_BASELINE") or read_first_line(self.baseline_file)
        self.baseline = self.baseline or self.baseline_file

        self.build_key_file = get("DEPLOY_AI_BUILD_KEY_FILE", "/etc/deploy-ai/build-key")
        self.build_key = get("DEPLOY_AI_BUILD_KEY") or read_first_line(self.build_key_file)
        self.build_key = self.build_key or "/var/lib/buildvm/secrets/id_ed25519"

        self.guest_candidate = get("DEPLOY_AI_GUEST_CANDIDATE", "/home/builder/deploy-candidate")
        self.recorded_commit = "/home/builder/deployed-commit"

        self.submit_max_bytes_file = get("DEPLOY_AI_SUBMIT_MAX_BYTES_FILE", "/etc/deploy-ai/submit-max-bytes")
        max_bytes = get("DEPLOY_AI_SUBMIT_MAX_BYTES") or read_first_line(self.submit_max_bytes_file)
        # Only a host with no file at all falls back here; an uncapped read from the guest is not an
        # option, so the value is checked where it is used rather than defaulted to "unbounded".
        self.submit_max_bytes_raw = max_bytes or str(DEFAULT_SUBMIT_MAX_BYTES)

        self.guest_only_file = get("DEPLOY_AI_GUEST_ONLY_FILE", "/etc/deploy-ai/guest-only-paths")
        self.deny_file = get("DEPLOY_AI_DENY_FILE", "/etc/deploy-ai/denylist")
        self.policy_file = get("DEPLOY_AI_POLICY_FILE", "/etc/deploy-ai/policy-digest")
        self.inbox = get("DEPLOY_AI_INBOX", os.path.join(self.state, "inbox"))
        self.guest_attr = get("DEPLOY_AI_GUEST_ATTR", "buildvm")
        self.recorded_guest_commit = get("DEPLOY_AI_RECORDED_GUEST_COMMIT", os.path.join(self.state, "guest-commit"))
        # The repository the guest computes its own `deployed..main` range in; the tag moves once a
        # submission is live.
        self.guest_repo = get("DEPLOY_AI_GUEST_REPO", "/home/builder/nixflakes")

        # Guest root's key, for the switch inside the VM.  As with the builder key, /etc publishes
        # only where it lives, so nothing here hardcodes a buildvm path.
        self.guest_root_key_file = get("DEPLOY_AI_GUEST_ROOT_KEY_FILE", "/etc/deploy-ai/guest-root-key")
        self.guest_root_key = get("DEPLOY_AI_GUEST_ROOT_KEY") or read_first_line(self.guest_root_key_file)

        self.repo = ""
        self.ref = ""
        self.dry_run = False
        self.build_local = False
        self.sha = ""
        self.toplevel = ""
        self.guest_toplevel = ""

    # ------------------------------------------------------------------ plumbing

    def need(self) -> None:
        if os.geteuid() != 0:
            die("must run as root (the deployer account reaches it with sudo)")
        if not os.access(self.allowlist_file, os.R_OK):
            die(f"{self.allowlist_file} is missing; enable nixflakes.deploy-ai on ai first")

    def run(self, argv, *, stdin=None, capture=False, timeout=None, env=None, cwd=None):
        """Run argv without a shell.  `stdin` is bytes or an open pipe (for `tar | tar`), and
        `capture` returns stdout text."""
        streaming = stdin is not None and not isinstance(stdin, (bytes, str))
        try:
            return subprocess.run(
                argv,
                input=None if streaming else stdin,
                stdin=stdin if streaming else None,
                stdout=subprocess.PIPE if capture else None,
                stderr=subprocess.PIPE if capture else None,
                text=capture,
                timeout=timeout,
                env=env,
                cwd=cwd,
            )
        except subprocess.TimeoutExpired:
            raise SystemExit(f"deploy-ai: refusing: {' '.join(argv[:3])} timed out after {timeout}s")
        except OSError as error:
            die(f"cannot run {argv[0]}: {error}")

    def ssh_command(self) -> str:
        """`GIT_SSH_COMMAND` for fetching: for a repo on the VM the guest key is the only identity
        accepted (`IdentitiesOnly`); for a git host it is offered alongside whatever root has."""
        base = ["ssh", "-o", "StrictHostKeyChecking=accept-new"]
        if "127.0.0.1:" in self.repo or "localhost:" in self.repo:
            return shlex.join(["ssh", "-i", self.build_key, "-o", "IdentitiesOnly=yes",
                               "-o", "StrictHostKeyChecking=accept-new"])
        if os.access(self.build_key, os.R_OK):
            return shlex.join(["ssh", "-i", self.build_key, "-o", "StrictHostKeyChecking=accept-new"])
        return shlex.join(base)

    def mirror(self) -> None:
        os.makedirs(self.state, exist_ok=True)
        if not os.path.isdir(self.mirror):
            if self.run(["git", "init", "--bare", "--quiet", self.mirror]).returncode != 0:
                die(f"cannot create {self.mirror}")
            self.run(["git", "--git-dir", self.mirror, "remote", "add", "origin", self.repo])
        self.run(["git", "--git-dir", self.mirror, "remote", "set-url", "origin", self.repo])
        env = dict(os.environ, GIT_SSH_COMMAND=self.ssh_command())
        result = self.run(
            ["git", "--git-dir", self.mirror, "fetch", "--quiet", "--prune", "origin",
             "+refs/heads/*:refs/heads/*"],
            env=env,
            capture=True,
        )
        if result.returncode != 0:
            die(f"cannot fetch {self.repo}; check the URL and that root's key (or the VM key) is authorized")

    def acquire_lock(self) -> None:
        os.makedirs(self.state, exist_ok=True)
        lock = os.path.join(self.state, "lock")
        try:
            os.mkdir(lock)
        except FileExistsError:
            die(f"another deploy-ai is running ({lock} exists); wait for it")
        self.lock = lock

    def release_lock(self) -> None:
        try:
            os.rmdir(self.lock)
        except OSError:
            pass

    # ------------------------------------------------------------------ scope and history guards

    def allowlist(self) -> list[str]:
        return path_list_file(self.allowlist_file)

    def nearest_dir(self, path: str) -> str:
        """Names the allowlist entries already covering the refused path's area, so a refusal says
        where the change is allowed to go rather than only that it cannot."""
        directory = os.path.dirname(path)
        hits = []
        for entry in self.allowlist():
            trimmed = entry.rstrip("/")
            if trimmed == directory or trimmed.startswith(directory + "/"):
                hits.append(entry)
            if path.startswith(trimmed + "/"):
                hits.append(entry)
        if hits:
            return " ".join(hits)
        if directory == "":
            return "no top-level files are allowed"
        return f"nothing under {directory} is allowed"

    def refuse_scope(self, path: str) -> None:
        print(f"deploy-ai: refusing: '{path}' is outside the deploy-ai allowlist.", file=sys.stderr)
        print(f"  allowlist:    {' '.join(self.allowlist())}", file=sys.stderr)
        print(f"  nearest dir:  {self.nearest_dir(path)}", file=sys.stderr)
        print("  move the change there, or ask the operator to widen nixflakes.deploy-ai.allowlist.",
              file=sys.stderr)
        raise SystemExit(1)

    def baseline_commit(self) -> str:
        recorded = os.path.join(self.state, "commit")
        if os.path.isfile(recorded):
            base = read_first_line(recorded)
        elif os.path.isfile(self.baseline_commit_file) and os.path.getsize(self.baseline_commit_file) > 0:
            base = read_first_line(self.baseline_commit_file)
        else:
            die(f"no baseline commit recorded; ask the operator to deploy {AI} once out-of-band")
        # A switch from a dirty tree records `<rev>-dirty`, which is no commit; compare against the
        # commit the snapshot came from, since the uncommitted part is caught by the content diff.
        if base.endswith("-dirty"):
            base = base[: -len("-dirty")]
            print(f"deploy-ai: note: the recorded baseline was a dirty tree; checking against {base}",
                  file=sys.stderr)
        if not base:
            die(f"no baseline commit recorded; ask the operator to deploy {AI} once out-of-band")
        return base

    def changed_paths(self, candidate: str) -> list[str]:
        """Every path that differs between the baseline source and the candidate tree.

        Content comparison, not names: a rewritten history cannot hide a changed file.  `git diff
        --no-index --name-status` rather than `diff -rq` because a reconstructed tree carries a
        `.git`, which recursive diff would report as one huge added directory; here the paths stay
        repo-relative and the excludes apply per path.  Added paths are named from the candidate,
        removed and modified ones from the baseline, so both prefixes are stripped.
        """
        result = self.run(["git", "diff", "--no-index", "--name-status",
                           self.baseline, candidate], capture=True)
        paths = set()
        for line in result.stdout.splitlines():
            _, _, path = line.partition("\t")
            if not path or path == "/dev/null":
                continue
            paths.add(self.relative(path, (self.baseline, candidate)))
        return sorted(
            path for path in paths
            if not any(path == name or path.startswith(name + "/") for name in DIFF_EXCLUDES)
        )

    @staticmethod
    def relative(path: str, roots) -> str:
        """Repo-relative, whichever tree the diff named."""
        for root in roots if isinstance(roots, tuple) else (roots,):
            prefix = root.rstrip("/") + "/"
            if path.startswith(prefix):
                return path[len(prefix):]
        return path

    def check_history(self, base: str) -> None:
        if self.run(["git", "--git-dir", self.mirror, "merge-base", "--is-ancestor", base, self.sha]).returncode != 0:
            die(f"{self.sha} does not have the deployed commit {base} in its history; rebase onto it, "
                f"or the operator deploys out-of-band")

    def check_scope(self, candidate: str) -> None:
        if not os.path.isdir(self.baseline):
            die(f"{self.baseline} is missing; the running system was built without "
                f"nixflakes.deploy-ai.deployedSource")
        entries = self.allowlist()
        for path in self.changed_paths(candidate):
            if not matches(path, entries):
                self.refuse_scope(path)

    # ------------------------------------------------------------------ submit guards

    def refuse_deny(self, path: str) -> None:
        print(f"deploy-ai: refusing: '{path}' is on the deploy-ai denylist.", file=sys.stderr)
        print(f"  denylist:     {' '.join(path_list_file(self.deny_file))}", file=sys.stderr)
        print("  it touches the deployment machinery itself, so the operator must apply that out-of-band.",
              file=sys.stderr)
        print(f"  {self.deny_file} names every entry.", file=sys.stderr)
        raise SystemExit(1)

    # The gate's own machinery is off-limits to a patch: the thing doing the vetting cannot vet a
    # change to itself.
    def check_deny(self, candidate: str) -> None:
        if not os.access(self.deny_file, os.R_OK):
            die(f"{self.deny_file} is missing; enable nixflakes.deploy-ai on ai first")
        entries = path_list_file(self.deny_file)
        for path in self.changed_paths(candidate):
            if matches(path, entries):
                self.refuse_deny(path)

    # A submission only stays inside the VM when every changed path is one the VM owns; anything
    # else can reach ai and has to go through ai's switch path.
    def classify_changes(self, candidate: str) -> str:
        if not os.access(self.guest_only_file, os.R_OK):
            die(f"{self.guest_only_file} is missing; enable nixflakes.deploy-ai on ai first")
        entries = path_list_file(self.guest_only_file)
        for path in self.changed_paths(candidate):
            if not matches(path, entries):
                return "ai"
        return "guest"

    # The policy digest is evaluated out of the patched tree, so a submission cannot quietly widen
    # what the gate enforces.  nix's own error stays on stderr.
    def policy_digest(self, tree: str) -> str:
        result = self.run(["nix", "eval", "--raw", "--accept-flake-config",
                           f"{tree}#nixosConfigurations.{AI}.config.nixflakes.deploy-ai.policyDigest"],
                          capture=True, timeout=EVAL_TIMEOUT)
        return result.stdout.strip() if result.returncode == 0 else ""

    # The digest evaluated from the patched tree must be the one ai already enforces.
    def check_policy(self, actual: str) -> None:
        want = read_first_line(self.policy_file)
        if not want:
            die(f"cannot read {self.policy_file}")
        if not actual:
            die(f"cannot evaluate nixflakes.deploy-ai.policyDigest of the submitted tree; nothing was applied")
        if actual != want:
            die("the patch changes the deployment policy (allowlist, keys, users, sudoers); "
                "the operator must apply that out-of-band")

    # ------------------------------------------------------------------ the guest

    # Guest-side paths are passed as argv of the remote command, so the guest cannot be steered out
    # of /home/builder by text it controls.
    def vm_ssh(self, command: str, *, timeout=None) -> subprocess.CompletedProcess:
        return self.run(["ssh", "-i", self.build_key, "-o", "BatchMode=yes",
                         "-o", "StrictHostKeyChecking=accept-new", "-o", "ConnectTimeout=10",
                         "-p", BUILD_PORT, f"{BUILDER}@{BUILD_HOST}", command], capture=True,
                        timeout=timeout)

    # The same host and port as vm_ssh(), as root, for the one command that needs privileges inside
    # the guest.  StrictHostKeyChecking=accept-new and no known_hosts: qemu's port forwards a single
    # guest that is re-created often.
    def guest_root_ssh(self, command: str) -> subprocess.CompletedProcess:
        return self.run(["ssh", "-i", self.guest_root_key, "-o", "BatchMode=yes",
                         "-o", "StrictHostKeyChecking=accept-new",
                         "-o", "UserKnownHostsFile=/dev/null", "-o", "ConnectTimeout=10",
                         "-p", BUILD_PORT, f"root@{BUILD_HOST}", command], capture=True)

    # One remote command shape for every transfer: the same ssh options vm_ssh() uses, with a local
    # tar stream on its stdin.
    def pipe_to_guest(self, pack: subprocess.Popen, remote: str) -> int:
        result = self.run(["ssh", "-i", self.build_key, "-o", "BatchMode=yes",
                           "-o", "StrictHostKeyChecking=accept-new", "-o", "ConnectTimeout=10",
                           "-p", BUILD_PORT, f"{BUILDER}@{BUILD_HOST}", remote],
                          stdin=pack.stdout, capture=True)
        pack.stdout.close()
        pack.wait()
        return result.returncode

    def unpack_remote(self, local_argv: list[str], *, exclude_git: bool = False) -> int:
        pack = subprocess.Popen(local_argv + (["--exclude=.git"] if exclude_git else []) + ["-cf", "-", "."],
                                stdout=subprocess.PIPE)
        return self.pipe_to_guest(pack, self.remote_unpack())

    # Hand a tree over as plain files; the VM needs no repo access to build, only its own key for
    # git-hosted flake inputs.  `.git` stays on ai: nothing about the host-side commit travels.
    def remote_unpack(self) -> str:
        return (f"rm -rf {shlex.quote(self.guest_candidate)} && "
                f"mkdir -p {shlex.quote(self.guest_candidate)} && "
                f"tar -x -C {shlex.quote(self.guest_candidate)}")

    def send_tree(self, tree: str) -> None:
        if self.unpack_remote(["tar", "-C", tree], exclude_git=True) != 0:
            die(f"cannot unpack the tree into {self.guest_candidate} on the VM")

    def send_candidate(self) -> None:
        pack = subprocess.Popen(["git", "--git-dir", self.mirror, "archive", "--format=tar", self.sha],
                                stdout=subprocess.PIPE)
        if self.pipe_to_guest(pack, self.remote_unpack()) != 0:
            die(f"cannot unpack {self.sha} into {self.guest_candidate} on the VM")

    def remote_build(self, attr: str, log: str) -> str:
        """Build `nixosConfigurations.<attr>` in the guest and return the output path it printed."""
        os.makedirs(os.path.join(self.state, "log"), exist_ok=True)
        print(f"deploy-ai: building nixosConfigurations.{attr} on the VM…")
        command = (f"cd {shlex.quote(self.guest_candidate)} && nix build --no-link --print-out-paths "
                   f"--accept-flake-config "
                   f"{shlex.quote(self.guest_candidate)}#nixosConfigurations.{attr}.config.system.build.toplevel")
        result = self.vm_ssh(command, timeout=BUILD_TIMEOUT)
        with open(log, "w", encoding="utf-8") as handle:
            handle.write(result.stdout)
            handle.write(result.stderr)
        if result.returncode != 0:
            sys.stderr.write("".join(result.stdout.splitlines(True)[-40:]))
            sys.stderr.write("".join(result.stderr.splitlines(True)[-40:]))
            die(f"build failed on the VM; log: {log}")
        printed = result.stdout.strip().splitlines()[-1] if result.stdout.strip() else ""
        if not printed.startswith("/nix/store/"):
            die("the VM build printed no output path")
        return printed

    def build_on_vm(self) -> None:
        self.toplevel = self.remote_build(AI, os.path.join(self.state, "log", "build.log"))
        print("deploy-ai: copying the closure back to ai…")
        env = dict(os.environ, NIX_SSHOPTS=f"-i {self.build_key} -p {BUILD_PORT} -o BatchMode=yes "
                                          "-o StrictHostKeyChecking=accept-new")
        result = self.run(["nix-copy-closure", "--from", f"{BUILDER}@{BUILD_HOST}", self.toplevel], env=env)
        if result.returncode != 0:
            die("nix-copy-closure failed; the VM is reachable but its store could not be read")

    def build_guest_system(self) -> None:
        self.guest_toplevel = self.remote_build(self.guest_attr, os.path.join(self.state, "log", "guest-build.log"))

    def build_local(self) -> None:
        print(f"deploy-ai: building nixosConfigurations.{AI} on ai…")
        log = os.path.join(self.state, "log", "build.log")
        os.makedirs(os.path.join(self.state, "log"), exist_ok=True)
        rev = self.run(["git", "--git-dir", self.mirror, "rev-parse", self.sha], capture=True).stdout.strip()
        flake = f"git+file://{self.mirror}?ref={rev}#nixosConfigurations.{AI}.config.system.build.toplevel"
        result = self.run(["nix", "build", "--no-link", "--print-out-paths", "--accept-flake-config", flake],
                          capture=True, timeout=BUILD_TIMEOUT)
        with open(log, "w", encoding="utf-8") as handle:
            handle.write(result.stdout)
            handle.write(result.stderr)
        if result.returncode != 0:
            sys.stderr.write("".join(result.stdout.splitlines(True)[-40:]))
            sys.stderr.write("".join(result.stderr.splitlines(True)[-40:]))
            die(f"build failed; log: {log}")
        self.toplevel = result.stdout.strip().splitlines()[-1] if result.stdout.strip() else ""

    # ai evaluates the same tree the VM just built.  A path ai does not recognize is a VM that built
    # something else, and activating it would run a system nobody vetted.
    def verify_output(self, attr: str, printed: str, tree: str) -> None:
        result = self.run(["nix", "eval", "--raw", "--accept-flake-config",
                           f"{tree}#nixosConfigurations.{attr}.config.system.build.toplevel.outPath"],
                          capture=True, timeout=EVAL_TIMEOUT)
        if result.returncode != 0:
            die(f"cannot evaluate the toplevel path of nixosConfigurations.{attr}; nothing was switched")
        expected = result.stdout.strip()
        if printed != expected:
            die(f"the VM's build output does not match what ai computed: {printed} != {expected}; "
                f"nothing was switched")

    # ------------------------------------------------------------------ switch

    def current_system(self) -> str:
        return os.path.realpath("/run/current-system")

    def check_health(self) -> bool:
        for unit in UNITS:
            if self.run(["systemctl", "is-active", "--quiet", unit]).returncode != 0:
                return False
        if self.run(["curl", "-fsS", "--max-time", "5", API]).returncode != 0:
            return False
        return self.vm_ssh("echo ok").returncode == 0

    def wait_health(self) -> bool:
        for _ in range(HEALTH_RETRIES):
            if self.check_health():
                return True
            time.sleep(HEALTH_WAIT)
        return False

    # Remember where to come back to, before touching the switch.
    def record_rollback(self, previous: str) -> None:
        with open(os.path.join(self.state, "rollback-previous"), "w", encoding="utf-8") as handle:
            handle.write(previous + "\n")
        open(os.path.join(self.state, "rollback-pending"), "a").close()

    def clear_rollback(self) -> None:
        try:
            os.remove(os.path.join(self.state, "rollback-pending"))
        except OSError:
            pass

    def rollback(self) -> bool:
        previous = read_first_line(os.path.join(self.state, "rollback-previous"))
        switcher = os.path.join(previous, "bin", "switch-to-configuration") if previous else ""
        if not previous or not os.access(switcher, os.X_OK):
            print("deploy-ai: no rollback target recorded; leaving the new system in place", file=sys.stderr)
            return False
        print(f"deploy-ai: rolling back to {previous}", file=sys.stderr)
        self.run([switcher, "switch"])
        return True

    def do_switch(self) -> None:
        if self.dry_run:
            print(f"deploy-ai: dry run; would switch ai to {self.toplevel}")
            return
        self.run([os.path.join(self.toplevel, "bin", "switch-to-configuration"), "switch"])

    # Tell the VM which commit is live, so the agent's own tree can be compared against reality.
    def record_in_guest(self, sha: str) -> None:
        if self.vm_ssh(f"printf '%s\\n' {shlex.quote(sha)} > {shlex.quote(self.recorded_commit)}").returncode != 0:
            print(f"deploy-ai: warning: could not write {self.recorded_commit} in the VM", file=sys.stderr)

    # The guard is a timed reboot: if the new system hangs, boot finds the recorded rollback.
    def arm_guard(self) -> None:
        if self.dry_run:
            return
        result = self.run(["systemctl", "reboot", "--when", f"+{GUARD_MINUTES}m"], capture=True)
        if result.returncode == 0:
            print(f"deploy-ai: guard armed: reboot in {GUARD_MINUTES}m unless cancelled by a healthy switch")
        else:
            print("deploy-ai: warning: timed reboot unavailable; no automatic reboot on a hang",
                  file=sys.stderr)

    def cancel_guard(self) -> None:
        self.run(["systemctl", "cancel", "--when"], capture=True)

    def finish_ai_records(self, sha: str) -> None:
        with open(os.path.join(self.state, "toplevel"), "w", encoding="utf-8") as handle:
            handle.write(self.toplevel + "\n")
        with open(os.path.join(self.state, "commit"), "w", encoding="utf-8") as handle:
            handle.write(sha + "\n")
        stamp = datetime.datetime.now().astimezone().isoformat(timespec="seconds")
        with open(os.path.join(self.state, "refs.log"), "a", encoding="utf-8") as handle:
            handle.write(f"{stamp}\t{sha}\t{self.toplevel}\n")

    # ------------------------------------------------------------------ commands

    def do_status(self) -> None:
        deployed = read_first_line(os.path.join(self.state, "commit")) or read_first_line(self.baseline_commit_file) or "none"
        toplevel = read_first_line(os.path.join(self.state, "toplevel")) or self.current_system()
        pending = read_first_line(os.path.join(self.state, "rollback-previous")) if os.path.exists(
            os.path.join(self.state, "rollback-pending")) else ""
        guest = read_first_line(self.recorded_guest_commit)
        if not guest:
            result = self.vm_ssh(f"head -n 1 {shlex.quote(self.recorded_commit)}")
            guest = result.stdout.strip() if result.returncode == 0 else ""
        print(f"deployed commit:    {deployed}")
        print(f"deployed toplevel:  {toplevel}")
        print(f"baseline source:    {self.baseline} "
              f"{'(present)' if os.path.exists(self.baseline) else '(missing)'}")
        print(f"pending rollback:   {pending or 'none'}")
        # ai's own record first; the VM's copy only tells us what it was last told, and only if it is up.
        print(f"guest commit:       {guest or 'none'}")
        print(f"policy:             {read_first_line(self.policy_file) or 'none'} (immutable by patch)")
        print("allowlist:")
        try:
            with open(self.allowlist_file, encoding="utf-8") as handle:
                for line in handle:
                    print(f"  {line.rstrip()}")
        except OSError:
            pass
        timers = self.run(["systemctl", "list-timers", "--all"], capture=True)
        for line in timers.stdout.splitlines():
            if "reboot" in line.lower():
                print(line)

    def switch_with_guards(self, sha: str, after_success) -> None:
        """The shared road: build, require the current system healthy, arm the guard, switch, roll
        back if the new system never becomes healthy."""
        current = self.current_system()
        self.record_rollback(current)

        # The current system must be healthy before a switch, or the switch hides an existing break.
        if not self.check_health():
            self.clear_rollback()
            die(f"the CURRENT system is already unhealthy; switching would hide that.  "
                f"Fix it out-of-band or reboot {AI}")

        # Armed only now: a build that fails after an hour must not leave a reboot pending.
        self.arm_guard()
        self.do_switch()

        if not self.wait_health():
            print("deploy-ai: the new system never became healthy; switching back", file=sys.stderr)
            self.rollback()
            self.clear_rollback()
            self.cancel_guard()
            die(f"deploy of {sha} failed and was rolled back; log: {os.path.join(self.state, 'log', 'build.log')}")

        self.clear_rollback()
        self.cancel_guard()
        after_success(sha)

    # `git archive` streams the commit's tree; `tar` needs somewhere to unpack it, and a bare mirror
    # has no worktree, so both directions go through a temporary directory.
    def archive_dir(self, sha: str) -> str:
        dest = tempfile.mkdtemp(prefix="deploy-ai-archive.")
        pack = subprocess.Popen(["git", "--git-dir", self.mirror, "archive", "--format=tar", sha],
                                stdout=subprocess.PIPE)
        unpack = self.run(["tar", "x", "-C", dest], stdin=pack.stdout)
        pack.stdout.close()
        pack.wait()
        if unpack.returncode != 0:
            shutil.rmtree(dest, ignore_errors=True)
            die(f"cannot unpack {sha} from {self.mirror}")
        return dest

    def unpack_local_tar(self, tree: str, dest: str) -> None:
        pack = subprocess.Popen(["tar", "-C", tree, "-cf", "-", "."], stdout=subprocess.PIPE)
        unpack = self.run(["tar", "x", "-C", dest], stdin=pack.stdout)
        pack.stdout.close()
        pack.wait()
        if unpack.returncode != 0:
            die(f"cannot unpack {tree} into {dest}")

    def do_deploy(self) -> None:
        self.need()
        if not self.repo:
            die("--repo is required; name the repository to read")
        self.mirror()
        rev = self.run(["git", "--git-dir", self.mirror, "rev-parse", "--verify", f"{self.ref}^{{commit}}"],
                       capture=True)
        self.sha = rev.stdout.strip() if rev.returncode == 0 else ""
        if not self.sha:
            die(f"{self.ref} does not exist in {self.repo}; run 'deploy-ai --repo \"{self.repo}\" --list'")

        base = self.baseline_commit()
        self.check_history(base)

        self.acquire_lock()
        work = tempfile.mkdtemp(prefix="deploy-ai-tree.")
        try:
            self.unpack_local_tar(self.archive_dir(self.sha), work)
            self.check_scope(work)

            if self.build_local:
                self.build_local()
            else:
                self.send_candidate()
                self.build_on_vm()

            self.switch_with_guards(self.sha, lambda sha: (
                self.finish_ai_records(sha),
                self.record_in_guest(sha),
                print(f"deploy-ai: ai is now running {sha} ({self.toplevel})"),
            ))
        finally:
            shutil.rmtree(work, ignore_errors=True)
            self.release_lock()

    def do_list(self) -> None:
        self.need()
        if not self.repo:
            die("--repo is required")
        self.mirror()
        refs = self.run(["git", "--git-dir", self.mirror, "for-each-ref",
                         "--format=%(refname) %(objectname:short) %(committerdate:relative)", "refs/heads"],
                        capture=True)
        sys.stdout.write(refs.stdout)
        print(f"deployed: {read_first_line(os.path.join(self.state, 'commit')) or 'none'}")

    # ------------------------------------------------------------------ submit

    # The series arrives on stdin: the deployer account's forced command passes it through.  Reading
    # one byte past the cap refuses an oversized submission without buffering all of it, and the
    # contents are never echoed.
    def save_incoming_patch(self) -> str:
        try:
            cap = int(self.submit_max_bytes_raw)
        except ValueError:
            die(f"{self.submit_max_bytes_file} does not hold an integer: '{self.submit_max_bytes_raw}'")
        try:
            os.makedirs(self.inbox, exist_ok=True)
            os.chmod(self.inbox, 0o700)
        except OSError:
            die(f"cannot create {self.inbox}")
        stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        dest = os.path.join(self.inbox, f"{stamp}-{os.getpid()}.patch")
        try:
            handle = open(dest, "wb")
            os.chmod(dest, 0o600)
        except OSError:
            die(f"cannot write {dest}")
        with handle:
            data = sys.stdin.buffer.read(cap + 1)
            handle.write(data)
        size = len(data)
        if size > cap:
            die(f"patch too large: {size} bytes, over the {cap} limit in {self.submit_max_bytes_file}")
        if size == 0:
            die("empty patch on stdin; nothing to submit")
        return dest

    # Rebuilds the candidate as ai's baseline plus the patch.  The guest sends a diff, never a tree,
    # so no guest-supplied path, file list, or commit object is trusted.  `git apply` rather than
    # `git am`: the guest's commit metadata is not trusted either, and one host-authored commit is
    # what the records name.
    def reconstruct_tree(self, patch: str, dest: str, base: str) -> None:
        if not os.path.isdir(self.baseline):
            die(f"{self.baseline} is missing; the running system was built without "
                f"nixflakes.deploy-ai.deployedSource")
        pack = subprocess.Popen(["tar", "-C", self.baseline, "-cf", "-", "."], stdout=subprocess.PIPE)
        unpack = self.run(["tar", "-x", "-C", dest], stdin=pack.stdout)
        pack.stdout.close()
        pack.wait()
        if unpack.returncode != 0:
            die(f"cannot copy {self.baseline} into {dest}")
        # A baseline from the store is read-only, and `git apply` has to rewrite the files it touches.
        for root, directories, files in os.walk(dest):
            for name in directories + files:
                path = os.path.join(root, name)
                try:
                    os.chmod(path, os.stat(path).st_mode | 0o200)
                except OSError:
                    pass
        self.run(["git", "-C", dest, "init", "--quiet"])
        if self.run(["git", "-C", dest, "apply", "--check", "-p1", patch]).returncode != 0:
            die(f"the patch does not apply to the deployed commit {base}; rebase it onto {base} and submit again")
        if self.run(["git", "-C", dest, "apply", "-p1", patch]).returncode != 0:
            die(f"the patch does not apply to the deployed commit {base}")
        self.run(["git", "-C", dest, "add", "-A"])
        commit = self.run(["git", "-C", dest, "-c", "user.name=deploy-ai",
                           "-c", "user.email=deploy-ai@localhost", "commit", "--quiet",
                           "-m", f"deploy-ai submit onto {base}"], capture=True)
        if commit.returncode != 0:
            die(f"cannot commit the reconstructed tree in {dest}")
        self.sha = self.run(["git", "-C", dest, "rev-parse", "HEAD"], capture=True).stdout.strip()

    # A guest-only submission switches the VM and leaves ai running what it runs now.
    def apply_guest(self, tree: str, sha: str) -> None:
        self.send_tree(tree)
        self.build_guest_system()
        self.verify_output(self.guest_attr, self.guest_toplevel, tree)

        if not self.guest_root_key:
            die(f"no key for guest root; set {self.guest_root_key_file} or DEPLOY_AI_GUEST_ROOT_KEY")
        if not os.access(self.guest_root_key, os.R_OK):
            die(f"{self.guest_root_key} is not readable; the guest switch needs it")
        print(f"deploy-ai: switching the VM to {self.guest_toplevel}…")
        result = self.guest_root_ssh(f"nixos-rebuild switch --flake "
                                     f"{shlex.quote(self.guest_candidate)}#{self.guest_attr} --accept-flake-config")
        if result.returncode != 0:
            sys.stderr.write(result.stdout)
            sys.stderr.write(result.stderr)
            die("the guest switch failed; ai is unchanged")

        # Records only: a switch that landed but could not be recorded is still live.
        try:
            with open(self.recorded_guest_commit, "w", encoding="utf-8") as handle:
                handle.write(sha + "\n")
        except OSError:
            print(f"deploy-ai: warning: could not write {self.recorded_guest_commit}", file=sys.stderr)
        self.record_in_guest(sha)
        if self.vm_ssh(f"git -C {shlex.quote(self.guest_repo)} tag -f deployed {shlex.quote(sha)}").returncode != 0:
            print(f"deploy-ai: warning: could not move the deployed tag in {self.guest_repo} in the VM",
                  file=sys.stderr)
        print(f"deploy-ai: the VM is now running {sha} ({self.guest_toplevel}); ai is unchanged")

    # Anything else takes the same road as --repo/--ref, including the rollback and health guards.
    def apply_on_ai(self, tree: str, sha: str) -> None:
        self.send_tree(tree)
        self.build_on_vm()
        self.verify_output(AI, self.toplevel, tree)
        self.switch_with_guards(sha, lambda recorded: (
            self.finish_ai_records(recorded),
            self.record_in_guest(recorded),
            self.record_guest_commit(recorded),
            print(f"deploy-ai: ai is now running {recorded} ({self.toplevel})"),
        ))

    def record_guest_commit(self, sha: str) -> None:
        try:
            with open(self.recorded_guest_commit, "w", encoding="utf-8") as handle:
                handle.write(sha + "\n")
        except OSError:
            pass

    def do_submit(self) -> None:
        self.need()
        if not os.access(self.policy_file, os.R_OK):
            die(f"{self.policy_file} is missing; enable nixflakes.deploy-ai on ai first")
        if self.build_local:
            die("--submit builds on the VM like every other deploy; --local belongs to --repo/--ref")

        self.acquire_lock()
        work = tempfile.mkdtemp(prefix="deploy-ai-submit.")
        try:
            patch = self.save_incoming_patch()
            base = self.baseline_commit()
            self.reconstruct_tree(patch, work, base)

            self.check_scope(work)
            self.check_deny(work)
            actual = self.policy_digest(work)
            self.check_policy(actual)
            classification = self.classify_changes(work)

            print(f"deploy-ai: submitted tree {self.sha}, onto {base}: class {classification}")
            for path in self.changed_paths(work):
                print(f"  changed:  {path}")
            print(f"  policy:   {actual}, unchanged from {self.policy_file}")

            if self.vet_only or self.dry_run:
                print(f"deploy-ai: nothing applied ({'--vet' if self.vet_only else '--dry-run'})")
                return
            if classification == "guest":
                self.apply_guest(work, self.sha)
            else:
                self.apply_on_ai(work, self.sha)
        finally:
            shutil.rmtree(work, ignore_errors=True)
            self.release_lock()


def parse_args(argv):
    parser = argparse.ArgumentParser(prog="deploy-ai", add_help=False, description=USAGE)
    parser.add_argument("--repo", default="")
    parser.add_argument("--ref", default="")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--local", action="store_true")
    parser.add_argument("--status", action="store_true")
    parser.add_argument("--list", action="store_true")
    parser.add_argument("--submit", action="store_true")
    parser.add_argument("--vet", action="store_true")
    parser.add_argument("-h", "--help", action="store_true")
    try:
        args, extra = parser.parse_known_args(argv)
    except SystemExit:
        # The gate's contract is the usage text and exit 1, not argparse's own exit codes.
        print(USAGE, file=sys.stderr)
        raise SystemExit(1)
    if extra or args.help:
        print(USAGE, file=sys.stderr if args.help is False else sys.stdout)
        raise SystemExit(1 if not args.help else 0)
    return args


def main(argv=None):
    os.umask(UMASK)
    args = parse_args(sys.argv[1:] if argv is None else argv)
    tool = DeployAI()
    tool.repo = args.repo
    tool.ref = args.ref
    tool.dry_run = args.dry_run
    tool.build_local = args.local
    tool.vet_only = args.vet

    if args.status:
        tool.need()
        tool.do_status()
        return 0
    if args.list:
        tool.do_list()
        return 0
    if args.submit or args.vet:
        tool.do_submit()
        return 0
    if not args.ref:
        print(USAGE, file=sys.stderr)
        return 1
    tool.do_deploy()
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except SystemExit:
        raise
    except KeyboardInterrupt:
        sys.exit(130)
