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
GUEST_ROOT = "root"
BUILD_TIMEOUT = 3600
EVAL_TIMEOUT = 600
HEALTH_RETRIES = 24
HEALTH_WAIT = 5
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

Every run ends with one machine-readable line: `result: ok` (nothing applied, or a status
read), `result: applied` (a system switched), `result: refused` (a guard said no), or
`result: failed` (a build, transfer, or switch broke partway through).  A refusal names the
patch; a failure names the step.

<url> is any git URL root can read: the git host, or a repository on the VM
(ssh://builder@127.0.0.1:2224/home/builder/nixflakes).  --repo is required for anything
that fetches, and the build always runs on the VM: ai has no place to build a system, and a
build here would evaluate a flake whose inputs ai cannot fetch.

--submit/--vet read a series from stdin, e.g.

  git format-patch --stdout deployed..main | ssh deployer@10.0.2.2 'deploy-ai --submit'

The patch is applied to the source of the running system, never to a tree the guest supplies.
A submission that changes only build-VM paths switches the build VM; anything else goes through
the switch path above, with the same rollback and health guards.
"""


def die(message: str) -> "NoReturn":
    """A guard said no to the patch or to the invocation, so nothing was applied."""
    print(f"deploy-ai: refusing: {message}", file=sys.stderr)
    print("result: refused", file=sys.stderr)
    raise SystemExit(1)


def fail(message: str) -> "NoReturn":
    """The patch passed the guards and something afterwards broke: a transfer, a build, a switch."""
    print(f"deploy-ai: failed: {message}", file=sys.stderr)
    print("result: failed", file=sys.stderr)
    raise SystemExit(1)


def short(sha: str) -> str:
    """A commit as a reader wants it: enough to recognize, short enough to scan.  Records keep the
    full hash; this is only for what is printed."""
    return sha[:10] if len(sha) > 10 else (sha or "none")


def hum(count: int) -> str:
    """A byte count read at a glance; the exact number and the cap stay in the refusal."""
    return f"{count / 1024:.1f}K" if count >= 1024 else f"{count}B"


def say(label: str, value: str) -> None:
    """One labelled row of a report block."""
    print(f"  {label:<9} {value}")


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

        # The key root uses to ssh *into* the guest, as `builder` for transfers and builds.  It is a
        # host-side login keypair generated by buildvm-install and authorized in the guest, never the
        # guest's own outbound key: that one authenticates the guest toward the git host, and offering
        # it inbound is the wrong direction.
        self.build_key_file = get("DEPLOY_AI_BUILD_KEY_FILE", "/etc/deploy-ai/build-key")
        self.build_key = get("DEPLOY_AI_BUILD_KEY") or read_first_line(self.build_key_file)
        self.build_key = self.build_key or "/var/lib/buildvm/keys/deploy-ai/id_ed25519"

        self.guest_candidate = get("DEPLOY_AI_GUEST_CANDIDATE", "/home/builder/deploy-candidate")
        self.recorded_commit = "/home/builder/deployed-commit"

        self.submit_max_bytes_file = get("DEPLOY_AI_SUBMIT_MAX_BYTES_FILE", "/etc/deploy-ai/submit-max-bytes")
        max_bytes = get("DEPLOY_AI_SUBMIT_MAX_BYTES") or read_first_line(self.submit_max_bytes_file)
        # Only a host with no file at all falls back here; an uncapped read from the guest is not an
        # option, so the value is checked where it is used rather than defaulted to "unbounded".
        self.submit_max_bytes_raw = max_bytes or str(DEFAULT_SUBMIT_MAX_BYTES)

        # What counts as healthy here, published by the module instead of named in this package.
        # Hardcoding it is what made every deploy refuse to switch: the gateway answers `GET
        # /health` (hermes-agent/gateway/platforms/api_server.py:1555) and has no `/api/v1/health`
        # route at all, so the old probe returned 404 and read as a dead api.  Both values go into
        # the policy digest, so a submitted patch cannot aim the probe at something that always
        # answers 200.
        self.health_units_file = get("DEPLOY_AI_HEALTH_UNITS", "/etc/deploy-ai/health-units")
        self.health_url_file = get("DEPLOY_AI_HEALTH_URL", "/etc/deploy-ai/health-url")

        self.guest_only_file = get("DEPLOY_AI_GUEST_ONLY_FILE", "/etc/deploy-ai/guest-only-paths")
        self.deny_file = get("DEPLOY_AI_DENY_FILE", "/etc/deploy-ai/denylist")
        self.policy_file = get("DEPLOY_AI_POLICY_FILE", "/etc/deploy-ai/policy-digest")
        self.inbox = get("DEPLOY_AI_INBOX", os.path.join(self.state, "inbox"))
        self.guest_attr = get("DEPLOY_AI_GUEST_ATTR", "buildvm")
        self.patch_size = 0
        self.submit_cap = 0
        self.recorded_guest_commit = get("DEPLOY_AI_RECORDED_GUEST_COMMIT", os.path.join(self.state, "guest-commit"))
        # The repository the guest computes its own `deployed..main` range in; the tag moves once a
        # submission is live.
        self.guest_repo = get("DEPLOY_AI_GUEST_REPO", "/home/builder/nixflakes")

        # Guest root's key, for the switch inside the VM.  As with the builder key, /etc publishes
        # only where it lives, so nothing here hardcodes a buildvm path.  A host that publishes only
        # one key uses it for both users, which is what ai does: one login keypair, authorized in the
        # guest as `builder` and as `root`.
        self.guest_root_key_file = get("DEPLOY_AI_GUEST_ROOT_KEY_FILE", "/etc/deploy-ai/guest-root-key")
        self.guest_root_key = (get("DEPLOY_AI_GUEST_ROOT_KEY") or read_first_line(self.guest_root_key_file)
                               or self.build_key)

        self.repo = ""
        self.ref = ""
        self.dry_run = False
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
            fail(f"{' '.join(argv[:3])} timed out after {timeout}s")
        except OSError as error:
            die(f"cannot run {argv[0]}: {error}")
    def ssh_command(self) -> str:
        """`GIT_SSH_COMMAND` for fetching: for a repo on the VM the guest key is the only identity
        accepted (`IdentitiesOnly`), and the VM's host key is re-issued on every reseed, so nothing is
        pinned here; for a git host the key is offered alongside whatever root has."""
        if "127.0.0.1:" in self.repo or "localhost:" in self.repo:
            return shlex.join(["ssh", "-i", self.build_key, "-o", "IdentitiesOnly=yes",
                               "-o", "StrictHostKeyChecking=accept-new",
                               "-o", "UserKnownHostsFile=/dev/null"])
        if os.access(self.build_key, os.R_OK):
            return shlex.join(["ssh", "-i", self.build_key, "-o", "StrictHostKeyChecking=accept-new"])
        return "ssh -o StrictHostKeyChecking=accept-new"

    def ensure_mirror(self) -> None:
        """`self.mirror` is the mirror's path, so this method cannot share that name: an instance
        attribute would shadow it and every caller would try to call a string."""
        os.makedirs(self.state, exist_ok=True)
        if not os.path.isdir(self.mirror):
            if self.run(["git", "init", "--bare", "--quiet", self.mirror]).returncode != 0:
                die(f"cannot create {self.mirror}")
            self.run(["git", "--git-dir", self.mirror, "remote", "add", "origin", self.repo])
        self.run(["git", "--git-dir", self.mirror, "remote", "set-url", "origin", self.repo])
        # A repo on the VM is reachable only as `builder`, so a missing key is a configuration refusal
        # rather than a fetch that broke partway through.
        if "127.0.0.1:" in self.repo or "localhost:" in self.repo:
            self.need_guest_key(BUILDER, self.build_key)
        env = dict(os.environ, GIT_SSH_COMMAND=self.ssh_command())
        result = self.run(
            ["git", "--git-dir", self.mirror, "fetch", "--quiet", "--prune", "origin",
             "+refs/heads/*:refs/heads/*"],
            env=env,
            capture=True,
        )
        if result.returncode != 0:
            fail(f"cannot fetch {self.repo}; check the URL and that root's key (or the VM key) is authorized")

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
        print(f"  nearest dir: {self.nearest_dir(path)}",
              file=sys.stderr)
        print(f"  move the change there, or ask the operator to widen nixflakes.deploy-ai.allowlist.",
              file=sys.stderr)
        print(f"  {' '.join(self.allowlist())} is what is allowed.", file=sys.stderr)
        print("result: refused", file=sys.stderr)
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
        """Require the candidate to descend from what is deployed, so a deploy cannot rewrite history.

        A gate deploy records the commit of the tree ai reconstructed, which lives in ai's retained
        base repository and never in the mirror being fetched, so an unresolvable base falls back to
        the commit the flake baseline came from; with neither in the mirror the check says it was
        skipped instead of refusing a legitimate deploy.
        """
        if not self.mirror_has(base):
            fallback = read_first_line(self.baseline_commit_file)
            if self.mirror_has(fallback):
                print(f"deploy-ai: note: {base} is not in {self.repo}; checking history against "
                      f"{fallback} instead", file=sys.stderr)
                base = fallback
            else:
                print(f"deploy-ai: warning: neither {base} nor {fallback or 'a recorded flake commit'} "
                      f"is in {self.repo}; the descendant check is skipped", file=sys.stderr)
                return
        if self.run(["git", "--git-dir", self.mirror, "merge-base", "--is-ancestor", base, self.sha]).returncode != 0:
            die(f"{self.sha} does not have the deployed commit {base} in its history; rebase onto it, "
                f"or the operator deploys out-of-band")

    def mirror_has(self, sha: str) -> bool:
        return bool(sha) and self.run(["git", "--git-dir", self.mirror, "cat-file", "-e",
                                       f"{sha}^{{commit}}"], capture=True).returncode == 0

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
        print("  it touches the deployment machinery itself, so the operator must apply that out-of-band.",
              file=sys.stderr)
        print(f"  {' '.join(path_list_file(self.deny_file))} are denied; "
              f"the full list is in {self.deny_file}.", file=sys.stderr)
        print("result: refused", file=sys.stderr)
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
    # One argv for every guest ssh.  `UserKnownHostsFile=/dev/null` on all of them: a reseed replaces
    # the guest's sshd host keys, and `accept-new` against a remembered key is a hard refusal, so
    # pinning a key that changes whenever the disk is rewritten would break every later deploy.
    def guest_ssh_argv(self, user: str, command: str) -> list[str]:
        key = self.build_key if user == BUILDER else self.guest_root_key
        self.need_guest_key(user, key)
        return ["ssh", "-i", key, "-o", "BatchMode=yes", "-o", "IdentitiesOnly=yes",
                "-o", "StrictHostKeyChecking=accept-new", "-o", "UserKnownHostsFile=/dev/null",
                "-o", "ConnectTimeout=10", "-p", BUILD_PORT, f"{user}@{BUILD_HOST}", command]

    # An unreadable key used to look like a broken transfer: ssh named it on stderr and the caller
    # threw the stderr away.  Name the file and the uid instead.
    def need_guest_key(self, user: str, key: str) -> None:
        if not key:
            die(f"no key to ssh into the VM as {user}; set {self.build_key_file} or DEPLOY_AI_BUILD_KEY")
        if not os.access(key, os.R_OK):
            die(f"{key} is not readable by uid {os.geteuid()}, the key deploy-ai sshes into the VM "
                f"with as {user}")

    def vm_ssh(self, command: str, *, timeout=None) -> subprocess.CompletedProcess:
        return self.run(self.guest_ssh_argv(BUILDER, command), capture=True, timeout=timeout)

    # The same host and port as vm_ssh(), as root, for the commands that need privileges inside the
    # guest: the in-guest `nixos-rebuild switch` of a guest-only deploy.
    def guest_root_ssh(self, command: str) -> subprocess.CompletedProcess:
        return self.run(self.guest_ssh_argv(GUEST_ROOT, command), capture=True)

    # One remote command shape for every transfer: the same ssh options vm_ssh() uses, with a local
    # tar stream on its stdin.  ssh's stderr is the only record of why a transfer died, so a failure
    # hands it back rather than a bare exit code.
    def pipe_to_guest(self, pack: subprocess.Popen, remote: str) -> str:
        result = self.run(self.guest_ssh_argv(BUILDER, remote), stdin=pack.stdout, capture=True)
        pack.stdout.close()
        pack.wait()
        if result.returncode != 0:
            return result.stderr.strip() or result.stdout.strip() or f"ssh exited {result.returncode}"
        if pack.returncode != 0:
            return f"the local tar exited {pack.returncode} while packing the tree to send"
        return ""

    def unpack_remote(self, local_argv: list[str], *, exclude_git: bool = False) -> str:
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
        failure = self.unpack_remote(["tar", "-C", tree], exclude_git=True)
        if failure:
            fail(f"cannot unpack the tree into {self.guest_candidate} on the VM: {failure}")

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
            fail(f"build failed on the VM; log: {log}")
        printed = result.stdout.strip().splitlines()[-1] if result.stdout.strip() else ""
        if not printed.startswith("/nix/store/"):
            fail("the VM build printed no output path")
        return printed

    def build_on_vm(self) -> None:
        self.toplevel = self.remote_build(AI, os.path.join(self.state, "log", "build.log"))
        print("deploy-ai: copying the closure back to ai…")
        env = dict(os.environ, NIX_SSHOPTS=f"-i {self.build_key} -p {BUILD_PORT} -o BatchMode=yes "
                                          "-o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new "
                                          "-o UserKnownHostsFile=/dev/null")
        result = self.run(["nix-copy-closure", "--from", f"{BUILDER}@{BUILD_HOST}", self.toplevel], env=env)
        if result.returncode != 0:
            fail("nix-copy-closure failed; the VM is reachable but its store could not be read")

    def build_guest_system(self) -> None:
        self.guest_toplevel = self.remote_build(self.guest_attr, os.path.join(self.state, "log", "guest-build.log"))

    # ai evaluates the same tree the VM just built.  A path ai does not recognize is a VM that built
    # something else, and activating it would run a system nobody vetted.
    def verify_output(self, attr: str, printed: str, tree: str) -> None:
        result = self.run(["nix", "eval", "--raw", "--accept-flake-config",
                           f"{tree}#nixosConfigurations.{attr}.config.system.build.toplevel.outPath"],
                          capture=True, timeout=EVAL_TIMEOUT)
        if result.returncode != 0:
            fail(f"cannot evaluate the toplevel path of nixosConfigurations.{attr}; nothing was switched")
        expected = result.stdout.strip()
        if printed != expected:
            fail(f"the VM's build output does not match what ai computed: {printed} != {expected}; "
                f"nothing was switched")

    # ------------------------------------------------------------------ switch

    def current_system(self) -> str:
        return os.path.realpath("/run/current-system")

    def api_answer(self) -> str:
        """The status code the configured health endpoint answers, or `''` when nothing is
        configured and `none` when nothing answered.

        `-w %{http_code}` instead of `-f` is the point: curl reports a 404 as a number rather than
        as a failed command, which is the difference between a wrong path and a dead server."""
        url = read_first_line(self.health_url_file)
        if not url:
            return ""
        result = self.run(
            ["curl", "-sS", "--max-time", "5", "-o", "/dev/null", "-w", "%{http_code}", url],
            capture=True,
        )
        if result.returncode != 0:
            return "none"
        return result.stdout.strip() or "none"

    def health_problems(self) -> list:
        """Why this system is not healthy, in the words a reader can act on."""
        problems = [f"{unit} inactive"
                    for unit in path_list_file(self.health_units_file)
                    if self.run(["systemctl", "is-active", "--quiet", unit]).returncode != 0]
        answer = self.api_answer()
        if not answer:
            problems.append("no health endpoint configured")
        elif answer == "none":
            problems.append("health endpoint answered nothing")
        elif answer[0] not in ("2", "3"):
            problems.append(f"health endpoint answered {answer}")
        return problems

    # Before a switch the whole road has to be sound: ai's services and the VM the build runs on.
    def check_health(self) -> bool:
        return not self.health_problems() and self.vm_ssh("echo ok").returncode == 0

    # After a switch only ai counts.  Switching ai restarts `buildvm-provision`, which rebuilds the
    # guest's system from ai's tree and reboots it, so the VM can be down for minutes while it
    # converges; counting that as a failed deploy would roll back a switch that is healthy on ai.
    def wait_health(self) -> bool:
        for _ in range(HEALTH_RETRIES):
            if not self.health_problems():
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
        # Written as guest root: a deploy that changes the guest's own users could remove `builder`,
        # and the marker has to survive the switch it is reporting on.
        if self.guest_root_ssh(f"printf '%s\\n' {shlex.quote(sha)} > {shlex.quote(self.recorded_commit)}").returncode != 0:
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

    def do_status(self) -> str:
        """One screen: what ai runs, whether it is healthy, what the VM was told, what happened last."""
        deployed = read_first_line(os.path.join(self.state, "commit")) or read_first_line(self.baseline_commit_file)
        pending = read_first_line(os.path.join(self.state, "rollback-previous")) if os.path.exists(
            os.path.join(self.state, "rollback-pending")) else ""
        print("deploy-ai: ai now")
        say("commit", short(deployed))
        say("system", read_first_line(os.path.join(self.state, "toplevel")) or self.current_system())
        say("health", self.health_row())
        say("rollback", pending or "none")
        say("guest", self.guest_row())
        say("baseline", f"{self.baseline} "
                        f"{'(present)' if os.path.exists(self.baseline) else '(missing)'}")
        # The digest itself is not something an agent acts on; what matters is that no patch can move it.
        say("policy", "locked; a patch cannot change it")
        say("allowed", " ".join(self.allowlist()) or "nothing")
        say("last", self.last_row())
        say("guard", self.guard_row())
        return "ok"

    def health_row(self) -> str:
        """What ai finds right now, in the order a switch checks it."""
        problems = self.health_problems()
        return "ok" if not problems else "down: " + ", ".join(problems)

    def guest_row(self) -> str:
        """What the VM was last told is live.  ai's own record wins; the VM's copy only says what it was
        told, and only if it is up.  A VM that cannot be reached is not a VM with nothing deployed."""
        guest = read_first_line(self.recorded_guest_commit)
        if guest:
            return short(guest)
        result = self.vm_ssh(f"head -n 1 {shlex.quote(self.recorded_commit)}")
        if result.returncode != 0:
            return "unknown, ssh to the VM failed: " + (result.stderr.strip() or f"exit {result.returncode}")
        return short(result.stdout.strip()) or "none"

    def last_row(self) -> str:
        """The tail of refs.log: when, which commit, and how it arrived."""
        try:
            with open(os.path.join(self.state, "refs.log"), encoding="utf-8") as handle:
                lines = [line.rstrip("\n") for line in handle if line.strip()]
        except OSError:
            return "none recorded"
        if not lines:
            return "none recorded"
        fields = lines[-1].split("\t")
        if len(fields) < 3:
            return fields[0]
        return f"{fields[0]}  {short(fields[1])}  {fields[2]}"

    def guard_row(self) -> str:
        """Whether the timed reboot that catches a hung switch is still pending."""
        shown = self.run(["systemctl", "show", "reboot", "--property=NextElapseSince1970Usec"],
                         capture=True)
        usec = shown.stdout.partition("=")[2].strip()
        if usec.isdigit() and int(usec) > 0:
            when = datetime.datetime.fromtimestamp(int(usec) / 1_000_000).astimezone()
            return "reboot armed at " + when.isoformat(timespec="minutes")
        return "none armed"

    def switch_with_guards(self, sha: str, after_success) -> None:
        """The shared road: build, require the current system healthy, arm the guard, switch, roll
        back if the new system never becomes healthy."""
        current = self.current_system()
        self.record_rollback(current)

        # The current system must be healthy before a switch, or the switch hides an existing break.
        if not self.check_health():
            self.clear_rollback()
            problems = self.health_problems()
            detail = ", ".join(problems) or f"the build VM at {BUILD_HOST}:{BUILD_PORT} is unreachable"
            die(f"the CURRENT system is already unhealthy ({detail}); switching would hide that.  "
                f"Fix it out-of-band or reboot {AI}")

        # Armed only now: a build that fails after an hour must not leave a reboot pending.
        self.arm_guard()
        self.do_switch()
        if self.dry_run:
            # Nothing was switched, so nothing is recorded: a record claims what is live, and
            # `--status` would read a dry run as a deploy.
            self.clear_rollback()
            print("deploy-ai: nothing applied (--dry-run)")
            return

        if not self.wait_health():
            print("deploy-ai: the new system never became healthy; switching back", file=sys.stderr)
            self.rollback()
            self.clear_rollback()
            self.cancel_guard()
            fail(f"deploy of {sha} failed and was rolled back; log: {os.path.join(self.state, 'log', 'build.log')}")

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
            fail(f"cannot unpack {sha} from {self.mirror}")
        return dest

    def unpack_local_tar(self, tree: str, dest: str) -> None:
        pack = subprocess.Popen(["tar", "-C", tree, "-cf", "-", "."], stdout=subprocess.PIPE)
        unpack = self.run(["tar", "x", "-C", dest], stdin=pack.stdout)
        pack.stdout.close()
        pack.wait()
        if unpack.returncode != 0:
            fail(f"cannot unpack {tree} into {dest}")

    def do_deploy(self) -> str:
        self.need()
        if not self.repo:
            die("--repo is required; name the repository to read")
        self.ensure_mirror()
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
            # The same road a submission takes: hand the tree to the VM, build there, copy the
            # closure back, and let ai re-derive the path before anything is switched.
            self.apply_on_ai(work, self.sha)
        finally:
            shutil.rmtree(work, ignore_errors=True)
            self.release_lock()
        return "ok" if self.dry_run else "applied"

    def do_list(self) -> str:
        self.need()
        if not self.repo:
            die("--repo is required")
        self.ensure_mirror()
        refs = self.run(["git", "--git-dir", self.mirror, "for-each-ref",
                         "--format=%(refname) %(objectname:short) %(committerdate:relative)", "refs/heads"],
                        capture=True)
        sys.stdout.write(refs.stdout)
        print(f"deployed: {short(read_first_line(os.path.join(self.state, 'commit')))}")
        return "ok"

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
        self.patch_size = size
        self.submit_cap = cap
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
            fail(f"cannot copy {self.baseline} into {dest}")
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
            fail(f"cannot commit the reconstructed tree in {dest}")
        self.sha = self.run(["git", "-C", dest, "rev-parse", "HEAD"], capture=True).stdout.strip()

    # The tip of the submitted series, read from its `From <sha>` headers, newest last.  It is only
    # ever used as a name inside the guest's own repository, never as a tree to trust.
    def series_tip(self, patch: str) -> str:
        tip = ""
        try:
            with open(patch, encoding="utf-8", errors="replace") as handle:
                for line in handle:
                    if line.startswith("From "):
                        fields = line.split()
                        tip = fields[1] if len(fields) > 1 else ""
        except OSError:
            return ""
        return tip if len(tip) >= 7 else ""

    # A gate-deployed tree has no commit in any repository: it is ai's baseline plus a patch, committed
    # in a temporary directory that is deleted when the deploy ends.  Keep a bare copy of it, so the
    # recorded commit stays resolvable for `--status`, for the next deploy's diff baseline, and for
    # `check_history`.
    def retain_base(self, tree: str) -> None:
        dest = os.path.join(self.state, "base.git")
        tmp = dest + ".tmp"
        shutil.rmtree(tmp, ignore_errors=True)
        if self.run(["git", "clone", "--quiet", "--bare", tree, tmp], capture=True).returncode != 0:
            print("deploy-ai: warning: could not keep the reconstructed commit; the next deploy can "
                  "still diff, but nothing will resolve this commit", file=sys.stderr)
            return
        try:
            shutil.rmtree(dest, ignore_errors=True)
            os.replace(tmp, dest)
        except OSError as error:
            print(f"deploy-ai: warning: could not record {dest}: {error}", file=sys.stderr)

    # A guest-only submission switches the VM and leaves ai running what it runs now.
    def apply_guest(self, tree: str, sha: str, series_tip: str = "") -> None:
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
            fail("the guest switch failed; ai is unchanged")

        # Records only: a switch that landed but could not be recorded is still live.
        try:
            with open(self.recorded_guest_commit, "w", encoding="utf-8") as handle:
                handle.write(sha + "\n")
        except OSError:
            print(f"deploy-ai: warning: could not write {self.recorded_guest_commit}", file=sys.stderr)
        # What the guest is told is live has to be a commit its own repository can resolve, so it gets
        # the tip of the series it pushed rather than ai's reconstructed commit, which exists only in
        # ai's retained base repository.
        record = series_tip or sha
        self.record_in_guest(record)
        if self.vm_ssh(f"git -C {shlex.quote(self.guest_repo)} tag -f deployed {shlex.quote(record)}").returncode != 0:
            print(f"deploy-ai: warning: could not move the deployed tag in {self.guest_repo} in the VM "
                  f"to {record}; the agent's 'deployed..main' range is stale",
                  file=sys.stderr)
        print(f"deploy-ai: the VM is now running {sha} ({self.guest_toplevel}); ai is unchanged; "
              f"the VM records {record} as deployed")

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

    def do_submit(self) -> str:
        self.need()
        if not os.access(self.policy_file, os.R_OK):
            die(f"{self.policy_file} is missing; enable nixflakes.deploy-ai on ai first")

        self.acquire_lock()
        work = tempfile.mkdtemp(prefix="deploy-ai-submit.")
        try:
            patch = self.save_incoming_patch()
            base = self.baseline_commit()
            self.reconstruct_tree(patch, work, base)
            self.retain_base(work)

            print(f"deploy-ai: {'--vet' if self.vet_only else '--submit'}: "
                  f"{short(self.sha)} onto {short(base)}")
            say("size", f"{hum(self.patch_size)} of {hum(self.submit_cap)} allowed")
            say("applies", "cleanly")
            # Rows appear as each check passes, so a refusal lands after the rows that held and before
            # the ones that never ran.
            self.check_scope(work)
            say("scope", "inside the allowlist")
            self.check_deny(work)
            say("denylist", "clear")
            self.check_policy(self.policy_digest(work))
            say("policy", "unchanged")
            classification = self.classify_changes(work)
            say("class", classification)
            for path in self.changed_paths(work):
                say("changed", path)

            if self.vet_only or self.dry_run:
                say("would", "switch the VM and reboot it" if classification == "guest"
                    else "build on the VM, switch ai, and reboot back if it never becomes healthy")
                print(f"deploy-ai: nothing applied ({'--vet' if self.vet_only else '--dry-run'})")
                return "ok"
            if classification == "guest":
                self.apply_guest(work, self.sha, self.series_tip(patch))
            else:
                self.apply_on_ai(work, self.sha)
            return "applied"
        finally:
            shutil.rmtree(work, ignore_errors=True)
            self.release_lock()


def parse_args(argv):
    parser = argparse.ArgumentParser(prog="deploy-ai", add_help=False, description=USAGE)
    parser.add_argument("--repo", default="")
    parser.add_argument("--ref", default="")
    parser.add_argument("--dry-run", action="store_true")
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
    # A deploy reports its verdict, then sshes; through a pipe stdout is block-buffered, which put the
    # verdict after whatever the guest wrote.  Line-buffer it so order on the wire is order here.
    try:
        sys.stdout.reconfigure(line_buffering=True)
    except (AttributeError, OSError):
        pass
    args = parse_args(sys.argv[1:] if argv is None else argv)
    tool = DeployAI()
    tool.repo = args.repo
    tool.ref = args.ref
    tool.dry_run = args.dry_run
    tool.vet_only = args.vet

    if args.status:
        tool.need()
        verdict = tool.do_status()
        print(f"result: {verdict}")
        return 0
    if args.list:
        verdict = tool.do_list()
        print(f"result: {verdict}")
        return 0
    if args.submit or args.vet:
        verdict = tool.do_submit()
        print(f"result: {verdict}")
        return 0
    if not args.ref:
        print(USAGE, file=sys.stderr)
        return 1
    verdict = tool.do_deploy()
    print(f"result: {verdict}")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except SystemExit:
        raise
    except KeyboardInterrupt:
        sys.exit(130)
