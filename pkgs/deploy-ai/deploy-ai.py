#!/usr/bin/env python3
"""deploy-ai — the only way anything changes ai's system.

Runs as root, normally through the forced-command account `deployer`, which the build VM's key is
authorized for.

Guards, in order: the deployed commit must be an ancestor of `--ref`, and the tree diff against the
source of the running system must stay inside `nixflakes.deploy-ai.allowlist` (plus its denylist and
the policy digest, for a submitted patch).  After the switch a failed health probe rolls back,
backed by a timed reboot guard.

Each machine builds what it runs.  ai's system is built here, capped by `--max-jobs`; the build VM
builds `#buildvm`, which it does itself when `buildvm-provision` converges it onto this tree after a
switch.  Nothing crosses between the two stores, so nothing is copied back and nothing is switched in
the guest from here: what the gate does against the VM is read-only, and the VM's own record of what
is live is provisioning's to write.  No repo lives on ai, so `--repo` names one on every call that
fetches, and `--submit` rebuilds the tree from ai's own recorded baseline instead of trusting the
guest.

Why Python rather than shell: the guards below are the security boundary, and their failure modes
were shell failure modes — `set -e` interacting with a loop's exit status, one `trap` replacing
another and leaking the lock directory, quoting inside a remote command string.  Every value still
reaches `git`/`ssh`/`nix`/`tar` as an argv list, so no shell parses any of them.
"""

import argparse
import datetime
import os
import re
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
# Used when ai publishes no number: a build here shares the machine with the api server, so the
# default has to be a cap rather than nix's own, which is every core.
DEFAULT_MAX_JOBS = 2
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

  deploy-ai --repo <url> --ref <rev>     build <rev> on ai and switch ai to it
  deploy-ai --repo <url> --ref <rev> --dry-run
  deploy-ai --repo <url> --list          refs visible in that repository
  deploy-ai --status                     what is deployed now, and why
  deploy-ai --submit                     vet a patch series on stdin and provision it immediately
  deploy-ai --vet                        the same checks, nothing applied; prints the verdict
  deploy-ai --submit --dry-run           vet and report, apply nothing
  deploy-ai --confirm-boot               point the next boot at the running generation (after a manual switch)
  deploy-ai --switch-toplevel <path> --sha <rev>
      internal: the switch tail run by the transient unit `deploy-ai-switch` a real deploy arms

Every run ends with one machine-readable line: `result: ok` (nothing applied, or a status
read), `result: applied` (a system switched), `result: refused` (a guard said no), or
`result: failed` (a build, a fetch, or a switch broke partway through).  A refusal names the
patch; a failure names the step.

<url> is any git URL root can read: the git host, or a repository on the VM
(ssh://builder@127.0.0.1:2224/home/builder/nixflakes).  --repo is required for anything
that fetches.  The build runs on ai, with --max-jobs taken from /etc/deploy-ai/build-max-jobs
so it cannot take every core from the api server.

/etc/deploy-ai/trusted-sources names `repo<TAB>ref` pairs (`nixflakes.deploy-ai.trustedSources`)
that the operator reviews at merge time.  A --repo/--ref run whose commit is the current tip of a
trusted branch is trusted content-wise: the allowlist and the descendant check are skipped because
merging the branch was the review.  Every other run takes the full scope checks, and no route ever
skips the health probe, the rollback, or the reboot guard.

--submit/--vet read a series from stdin, e.g.

  git format-patch --stdout deployed..main | ssh deployer@10.0.2.2 'deploy-ai --submit'

The patch is applied to the source of the running system, never to a tree the guest supplies.
Every submission takes the switch path above, with the same rollback and health guards: a change to
the build VM's own files lands on ai first, and the guest picks it up when provisioning rebuilds it
from ai's tree.
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


GATE_WRAPPER = "/run/current-system/sw/bin/deploy-ai"


def gate_binary(argv0: str) -> str:
    """The path the transient switch unit uses to re-enter this gate.

    It must be the executable wrapper installed in the system profile — the same entry point the
    gate shell execs.  The gate's own store `.py` cannot be the unit's command: store Python files
    are mode 0444, and execve refuses files with no execute bit even for root, so systemd answers
    203/EXEC with `Permission denied`.  Over ssh `argv[0]` is often that `.py` (the wrapper runs
    `python3 <store path>`), and `shutil.which()` hands an absolute path straight back, so a bare
    PATH lookup cannot be trusted to find something exec'able.  Fall back to PATH/argv0 only when
    the wrapper is absent, and refuse rather than hand systemd a doomed path."""
    if os.access(GATE_WRAPPER, os.X_OK):
        return GATE_WRAPPER
    resolved = shutil.which(argv0) or os.path.realpath(argv0)
    if not os.access(resolved, os.X_OK):
        die(f"the switch unit needs an executable deploy-ai: neither {GATE_WRAPPER} nor "
            f"{resolved} can be exec'd")
    return resolved


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


def canonical_repo(url: str) -> str:
    """Repo identity for the trust check: `host/path`, with scheme, credentials, port, and a
    trailing `.git` ignored so the https and ssh forms of one repository are one identity.  The
    host stays load-bearing: a repository on the VM (`127.0.0.1`) must never stand in for the
    git host however its URL is spelled, and dropping only the port keeps that distinction
    while letting either URL form of the real host match.
    """
    u = url.strip().lower()
    if "://" in u:
        rest = u.split("://", 1)[1]
        if "@" in rest.split("/", 1)[0]:
            rest = rest.split("@", 1)[1]
        host, _, path = rest.partition("/")
    else:  # scp-style `git@host:path`
        user_host, _, path = u.partition(":")
        host = user_host.rsplit("@", 1)[-1]
    host = host.split(":")[0]
    path = path.rstrip("/")
    if path.endswith(".git"):
        path = path[: -len(".git")]
    return f"{host}/{path}"


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
        # A gate deploy replaces what ai runs, but `deployed-source` was written by the module at
        # build time and never moves: patches rebased onto the deployed commit would otherwise
        # apply onto a stale tree. Each successful deploy caches the tree it landed here, and the
        # next deploy measures against the cache. The store path remains the fallback for a gate
        # that has never deployed through it.
        self.base_cache = os.path.join(self.state, "base-tree")

        # The key root uses to ssh *into* the guest as `builder`, for the read-only probes.  It is a
        # host-side login keypair generated by buildvm-install and authorized in the guest, never the
        # guest's own outbound key: that one authenticates the guest toward the git host, and offering
        # it inbound is the wrong direction.
        self.build_key_file = get("DEPLOY_AI_BUILD_KEY_FILE", "/etc/deploy-ai/build-key")
        self.build_key = get("DEPLOY_AI_BUILD_KEY") or read_first_line(self.build_key_file)
        self.build_key = self.build_key or "/var/lib/buildvm/keys/deploy-ai/id_ed25519"

        self.recorded_commit = "/home/builder/deployed-commit"

        # systemd-boot's `default` decides what the next boot runs.  A deploy pins it to the
        # running generation before switching and to the new one only once health passes, so a
        # reboot between those two points rolls back by itself — no pending file to strand and
        # nothing for anyone to remember to delete.
        self.boot_conf = get("DEPLOY_AI_BOOT_CONF", "/boot/loader/loader.conf")
        self.boot_entries = get("DEPLOY_AI_BOOT_ENTRIES", "/boot/loader/entries")
        self.system_profile = get("DEPLOY_AI_SYSTEM_PROFILE", "/nix/var/nix/profiles/system")

        # logind's schedule file is the authoritative record of a pending timed reboot: the
        # transient-timer property `systemctl show` reports can read empty while the reboot is
        # still scheduled, so both the guard status and its cancel check this file.
        self.shutdown_schedule = get("DEPLOY_AI_SHUTDOWN_SCHEDULE", "/run/systemd/shutdown/scheduled")

        # How much of the machine a build here may take, published by the module so this package
        # names no ai-specific value.
        self.max_jobs_file = get("DEPLOY_AI_MAX_JOBS", "/etc/deploy-ai/build-max-jobs")
        self.max_jobs = read_first_line(self.max_jobs_file) or str(DEFAULT_MAX_JOBS)

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

        self.deny_file = get("DEPLOY_AI_DENY_FILE", "/etc/deploy-ai/denylist")
        self.policy_file = get("DEPLOY_AI_POLICY_FILE", "/etc/deploy-ai/policy-digest")
        # Repo+branch pairs the operator reviews at merge time, published by the module.  The
        # trust file belongs to the running system and is inside the policy digest, so neither a
        # candidate tree nor a submitted patch can vouch for itself.
        self.trusted_file = get("DEPLOY_AI_TRUSTED_SOURCES", "/etc/deploy-ai/trusted-sources")
        self.inbox = get("DEPLOY_AI_INBOX", os.path.join(self.state, "inbox"))
        self.patch_size = 0
        self.submit_cap = 0

        self.repo = ""
        self.ref = ""
        self.dry_run = False
        self.sha = ""
        self.toplevel = ""

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
            self.need_guest_key()
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
        while True:
            try:
                os.mkdir(lock)
                break
            except FileExistsError:
                holder = self.lock_holder(lock)
                if holder:
                    die(f"another deploy-ai is running (pid {holder}); wait for it")
                # A directory that outlived its holder means the previous gate died between
                # acquire and release — activation severing the ssh session mid-deploy is exactly
                # that — so without reclaiming it every later deploy refuses until someone root-
                # deletes the lock, which the deployer cannot do.
                try:
                    os.remove(os.path.join(lock, "pid"))
                    os.rmdir(lock)
                except OSError:
                    die(f"{lock} exists and cannot be reclaimed: {os.listdir(lock)}")
        with open(os.path.join(lock, "pid"), "w", encoding="utf-8") as handle:
            handle.write(str(os.getpid()) + "\n")
        self.lock = lock

    def lock_holder(self, lock: str) -> str:
        """The pid of a live deploy-ai holding the lock, or '' when no holder is alive."""
        try:
            with open(os.path.join(lock, "pid"), encoding="utf-8") as handle:
                pid = handle.readline().strip()
        except OSError:
            return ""
        if not pid.isdigit():
            return ""
        try:
            with open(f"/proc/{pid}/cmdline", "rb") as handle:
                cmdline = handle.read().replace(b"\0", b" ").decode(errors="replace")
        except OSError:
            return ""
        return pid if "deploy-ai" in cmdline else ""

    def release_lock(self) -> None:
        try:
            os.remove(os.path.join(self.lock, "pid"))
        except OSError:
            pass
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

    def effective_base(self) -> str:
        """The tree patches apply onto and diffs are measured against.

        Prefer the cache written by the last successful gate deploy; it names what is actually
        running.  Fall back to the recorded flake source only when no deploy has been cached.
        """
        if os.path.isdir(self.base_cache) and os.listdir(self.base_cache):
            return self.base_cache
        return self.baseline

    def cache_base_tree(self, tree: str) -> None:
        """Record the tree just deployed as the base for the next patch or deploy."""
        dest = self.base_cache
        tmp = dest + ".tmp"
        shutil.rmtree(tmp, ignore_errors=True)
        try:
            shutil.copytree(tree, tmp, ignore=shutil.ignore_patterns(".git"))
            shutil.rmtree(dest, ignore_errors=True)
            os.replace(tmp, dest)
        except OSError as error:
            print(f"deploy-ai: warning: could not cache the deployed tree in {dest}: {error}",
                  file=sys.stderr)

    def changed_paths(self, candidate: str) -> list[str]:
        """Every path that differs between the baseline source and the candidate tree.

        Content comparison, not names: a rewritten history cannot hide a changed file.  `git diff
        --no-index --name-status` rather than `diff -rq` because a reconstructed tree carries a
        `.git`, which recursive diff would report as one huge added directory; here the paths stay
        repo-relative and the excludes apply per path.  Added paths are named from the candidate,
        removed and modified ones from the baseline, so both prefixes are stripped.
        """
        base = self.effective_base()
        result = self.run(["git", "diff", "--no-index", "--name-status",
                           base, candidate], capture=True)
        paths = set()
        for line in result.stdout.splitlines():
            _, _, path = line.partition("\t")
            if not path or path == "/dev/null":
                continue
            paths.add(self.relative(path, (base, candidate)))
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

    def trusted_sources(self) -> list[tuple[str, str]]:
        """`/etc/deploy-ai/trusted-sources`: `<repo>\t<ref>` lines naming repo+branch pairs the
        operator reviews at merge time.  Read from the running system, so a candidate cannot
        vouch for itself, and inside `policyDigest`, so a submitted patch cannot widen the trust
        it is vetted against.
        """
        if not os.access(self.trusted_file, os.R_OK):
            return []
        entries = []
        with open(self.trusted_file) as handle:
            for line in handle.read().splitlines():
                repo, _, ref = line.partition("\t")
                repo, ref = repo.strip(), ref.strip()
                if repo and ref:
                    entries.append((repo, ref))
        return entries

    def trust_match(self) -> str:
        """Why this run is a trusted deploy (a reason string), or `""`.  The commit must be the
        current tip of a trusted branch -- not merely one of its ancestors -- so a trusted deploy
        applies exactly what upstream made the head of that branch, and any older commit still
        takes the scope checks it would have been vetted against.
        """
        if not self.repo or not self.sha:
            return ""
        mine = canonical_repo(self.repo)
        for repo, ref in self.trusted_sources():
            if canonical_repo(repo) != mine:
                continue
            tip = self.run(["git", "--git-dir", self.mirror, "rev-parse", "--verify",
                            f"refs/heads/{ref}^{{commit}}"], capture=True)
            if tip.returncode == 0 and tip.stdout.strip() == self.sha:
                return f"{mine} refs/heads/{ref}"
        return ""

    def check_history(self, base: str, trusted: bool = False) -> None:
        """Require the candidate to descend from what is deployed, so a deploy cannot rewrite history.

        A gate deploy records the commit of the tree ai reconstructed, which lives in ai's retained
        base repository and never in the mirror being fetched, so an unresolvable base falls back to
        the commit the flake baseline came from; with neither in the mirror the check says it was
        skipped instead of refusing a legitimate deploy.  A trusted tip skips the refusal: its
        lineage is upstream's merge review, not the gate's ancestry check.
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
            if trusted:
                print(f"deploy-ai: note: {self.sha} is the tip of a trusted branch; the descendant "
                      f"check against {base} is skipped -- merging was the review", file=sys.stderr)
                return
            die(f"{self.sha} does not have the deployed commit {base} in its history; rebase onto it, "
                f"or the operator deploys out-of-band")

    def mirror_has(self, sha: str) -> bool:
        return bool(sha) and self.run(["git", "--git-dir", self.mirror, "cat-file", "-e",
                                       f"{sha}^{{commit}}"], capture=True).returncode == 0

    def check_scope(self, candidate: str) -> None:
        if not os.path.isdir(self.effective_base()):
            die(f"{self.effective_base()} is missing; the running system was built without "
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

    # ------------------------------------------------------------------ nix invocations

    # The policy digest is evaluated out of the patched tree, so a submission cannot quietly widen
    # what the gate enforces.  nix's own error stays on stderr.
    def policy_digest(self, tree: str) -> str:
        result = self.run(["nix", "eval", "--raw", "--accept-flake-config"]
                          + [f"{tree}#nixosConfigurations.{AI}.config.nixflakes.deploy-ai.policyDigest"],
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
    # One argv for every guest ssh, all of it as `builder`: the gate reads from the VM and never
    # writes to it or switches it.  `UserKnownHostsFile=/dev/null` because a reseed replaces the
    # guest's sshd host keys, and `accept-new` against a remembered key is a hard refusal, so pinning
    # a key that changes whenever the disk is rewritten would break every later deploy.
    def guest_ssh_argv(self, command: str) -> list[str]:
        self.need_guest_key()
        return ["ssh", "-i", self.build_key, "-o", "BatchMode=yes", "-o", "IdentitiesOnly=yes",
                "-o", "StrictHostKeyChecking=accept-new", "-o", "UserKnownHostsFile=/dev/null",
                "-o", "ConnectTimeout=10", "-p", BUILD_PORT, f"{BUILDER}@{BUILD_HOST}", command]

    # An unreadable key used to look like a broken transfer: ssh named it on stderr and the caller
    # threw the stderr away.  Name the file and the uid instead.
    def need_guest_key(self) -> None:
        if not self.build_key:
            die(f"no key to ssh into the VM as {BUILDER}; set {self.build_key_file} or DEPLOY_AI_BUILD_KEY")
        if not os.access(self.build_key, os.R_OK):
            die(f"{self.build_key} is not readable by uid {os.geteuid()}, the key deploy-ai sshes "
                f"into the VM with as {BUILDER}")

    def vm_ssh(self, command: str, *, timeout=None) -> subprocess.CompletedProcess:
        return self.run(self.guest_ssh_argv(command), capture=True, timeout=timeout)

    # The build runs here, as the uid that will run the result.  What makes that safe to do next
    # to a production api server is `--max-jobs` coming from ai, so a build cannot claim every
    # core.  Nothing is copied afterwards: this store holds what this store
    # built, and the build VM gets its system from provisioning, which builds it inside the guest.
    def build_on_ai(self, tree: str) -> None:
        os.makedirs(os.path.join(self.state, "log"), exist_ok=True)
        log = os.path.join(self.state, "log", "build.log")
        print(f"deploy-ai: building nixosConfigurations.{AI} on ai…")
        argv = ["nix", "build", "--no-link", "--print-out-paths", "--accept-flake-config"]
        argv += ["--max-jobs", self.max_jobs]
        argv += [f"{tree}#nixosConfigurations.{AI}.config.system.build.toplevel"]
        result = self.run(argv, capture=True, timeout=BUILD_TIMEOUT)
        with open(log, "w", encoding="utf-8") as handle:
            handle.write(result.stdout)
            handle.write(result.stderr)
        if result.returncode != 0:
            sys.stderr.write("".join(result.stdout.splitlines(True)[-40:]))
            sys.stderr.write("".join(result.stderr.splitlines(True)[-40:]))
            fail(f"build failed on ai; log: {log}")
        printed = result.stdout.strip().splitlines()[-1] if result.stdout.strip() else ""
        if not printed.startswith("/nix/store/"):
            fail("the build printed no output path")
        self.toplevel = printed

    # What gets built and evaluated: the tree without the `.git` a reconstruction creates.
    # `nixflakes.deploy-ai.deployedCommit` is `self.rev or self.dirtyRev`, so a tree carrying a
    # repository puts a commit into the running system that exists only in a directory deleted when the
    # deploy ends -- and provisioning hands that commit to the guest as what is live.  A tree with no
    # `.git` is a plain path flake with no `self.rev`, which is what `git archive` produces and
    # therefore what a `--repo/--ref` deploy has always built.
    def build_view(self, tree: str) -> str:
        """The tree as it is built, without host git metadata.  A tree carrying none is returned as it
        stands, so the road that reconstructs nothing pays nothing for it."""
        if not os.path.isdir(os.path.join(tree, ".git")):
            return tree
        dest = tempfile.mkdtemp(prefix="deploy-ai-build.")
        try:
            self.unpack_local_tar(tree, dest, exclude_git=True)
        except BaseException:
            shutil.rmtree(dest, ignore_errors=True)
            raise
        return dest

    # The path built must be the path evaluated from the same source.  A build
    # and an eval that disagree ran against different content or different flags, and activating what
    # was built would run a system nobody derived.
    def verify_output(self, attr: str, printed: str, tree: str) -> None:
        result = self.run(["nix", "eval", "--raw", "--accept-flake-config"]
                          + [f"{tree}#nixosConfigurations.{attr}.config.system.build.toplevel.outPath"],
                          capture=True, timeout=EVAL_TIMEOUT)
        if result.returncode != 0:
            fail(f"cannot evaluate the toplevel path of nixosConfigurations.{attr}; nothing was switched")
        expected = result.stdout.strip()
        if printed != expected:
            fail(f"the build output does not match what ai evaluated: {printed} != {expected}; "
                 "nothing was switched")

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

    # Before a switch the whole road has to be sound: ai's services, and the VM that has to converge on
    # whatever this switch puts in place.
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

    def read_rollback_previous(self) -> str:
        return read_first_line(os.path.join(self.state, "rollback-previous")) or ""

    # The rollback itself is systemd-boot's `default`: what the next boot runs.  A deploy pins it
    # to the running generation before the switch and moves it to the new generation only once
    # health passes, so a reboot anywhere between the two boots the old generation on its own.
    # Nothing rewrites the pin at boot: a deploy that died, or a switch made outside the gate,
    # leaves it where it was, and `--confirm-boot` is the repair.
    def boot_default_entry(self) -> str:
        try:
            with open(self.boot_conf, encoding="utf-8") as handle:
                for line in handle:
                    if line.startswith("default"):
                        return line.split(None, 1)[1].strip()
        except (OSError, IndexError):
            pass
        return ""

    def boot_entry_for(self, toplevel: str) -> str:
        """The loader entry that boots `toplevel`, found by the `init=` option naming it."""
        marker = os.path.basename(toplevel) + "/init"
        try:
            names = sorted(os.listdir(self.boot_entries))
        except OSError:
            return ""
        for name in names:
            try:
                with open(os.path.join(self.boot_entries, name), encoding="utf-8") as handle:
                    if marker in handle.read():
                        return name
            except OSError:
                continue
        return ""

    def install_boot_entry(self, toplevel: str) -> str:
        """The loader entry that boots `toplevel`, installing it when none exists.  A switch can
        activate a new system without ever writing its loader entry (the installer runs on `boot`
        actions, not on every switch), so the entry a deploy pins has to be made here first.
        The installer writes entries only for generations linked as system profiles, and a deploy
        builds `--no-link`, so link first -- the same link nixos-rebuild performs."""
        entry = self.boot_entry_for(toplevel)
        if entry or self.dry_run:
            return entry
        self.link_profile(toplevel)
        result = self.run([os.path.join(toplevel, "bin", "switch-to-configuration"), "boot"], capture=True)
        if result.returncode != 0:
            # Without this the installer's refusal is swallowed and the caller only sees "no entry".
            print(f"deploy-ai: boot-loader install failed (exit {result.returncode}): "
                  f"{(result.stderr or result.stdout or '').strip()[:400]}", file=sys.stderr)
        return self.boot_entry_for(toplevel)

    def link_profile(self, toplevel: str) -> None:
        """Link `toplevel` as a system generation profile.  systemd-boot's installer enumerates
        `system-N-link` symlinks in /nix/var/nix/profiles and refuses when there are none, so a
        deployed toplevel needs a profile to get a boot entry (and the profile doubles as a GC
        root keeping the rollback target alive).  Written directly: the link format is just
        symlinks, and the nix CLI has no profile-link command deploy-ai could call here."""
        current = os.path.realpath(self.system_profile)
        if current == os.path.realpath(toplevel):
            return
        profiles_dir = os.path.dirname(self.system_profile)
        prefix = os.path.basename(self.system_profile) + "-"
        generations = [
            int(name[len(prefix) : -len("-link")])
            for name in os.listdir(profiles_dir)
            if name.startswith(prefix) and name.endswith("-link")
        ]
        new_link = f"{prefix}{max(generations, default=0) + 1}-link"
        os.symlink(os.path.realpath(toplevel), os.path.join(profiles_dir, new_link))
        os.symlink(new_link, f"{self.system_profile}.new")
        os.rename(f"{self.system_profile}.new", self.system_profile)

    def set_loader_default(self, entry: str) -> bool:
        """Point the next boot at `entry`.  systemd-boot reads `default` from loader.conf;
        `bootctl set-default` performs that same edit but refuses machines not booted *via*
        systemd-boot (qemu-booted test VMs), a precondition pinning never needed."""
        try:
            with open(self.boot_conf, encoding="utf-8") as handle:
                lines = handle.readlines()
        except OSError:
            lines = []
        kept = [line for line in lines if not line.startswith("default")]
        kept.append(f"default {entry}\n")
        try:
            tmp = self.boot_conf + ".tmp"
            with open(tmp, "w", encoding="utf-8") as handle:
                handle.writelines(kept)
            os.replace(tmp, self.boot_conf)
        except OSError:
            return False
        return True

    def pin_boot(self, entry: str) -> bool:
        if self.dry_run or not entry:
            return False
        if not self.set_loader_default(entry):
            print(f"deploy-ai: warning: could not pin {entry} in {self.boot_conf}; "
                  "a reboot will boot the newest generation", file=sys.stderr)
            return False
        return True

    def confirm_boot(self) -> None:
        """Point the next boot at the running generation: the repair after an out-of-band switch,
        when a dead deploy had left the pin on the generation before it."""
        self.need()
        entry = self.install_boot_entry(self.current_system())
        if not entry:
            die("no systemd-boot entry names the running system; nothing to confirm")
        if not self.set_loader_default(entry):
            fail(f"could not write the loader default for {entry} in {self.boot_conf}")
        print(f"deploy-ai: the next boot runs the running generation ({entry})")

    def rollback(self) -> bool:
        previous = read_first_line(os.path.join(self.state, "rollback-previous"))
        switcher = os.path.join(previous, "bin", "switch-to-configuration") if previous else ""
        if not previous or not os.access(switcher, os.X_OK):
            print("deploy-ai: no rollback target recorded; leaving the new system in place", file=sys.stderr)
            return False
        print(f"deploy-ai: rolling back to {previous}", file=sys.stderr)
        result = self.run([switcher, "switch"])
        if result.returncode != 0:
            print(f"deploy-ai: the rollback switch exited {result.returncode}", file=sys.stderr)
            return False
        return True

    def do_switch(self) -> None:
        if self.dry_run:
            print(f"deploy-ai: dry run; would switch ai to {self.toplevel}")
            return
        result = self.run([os.path.join(self.toplevel, "bin", "switch-to-configuration"), "switch"])
        if result.returncode != 0:
            fail(f"the switch failed: switch-to-configuration exit {result.returncode}")

    # The guard is a timed reboot.  While the pin points at the old generation, that reboot is
    # the rollback a hung new system needs; the tail cancels it once health has passed.
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
        # The schedule file is the proof of cancellation, not the exit code: a switch's activation
        # can restart dbus/logind at exactly this moment, and one swallowed failure would leave the
        # host scheduled to reboot an hour later.  Retry until the file is gone, then say so rather
        # than pretend the guard stood down.
        for _ in range(6):
            if not os.path.exists(self.shutdown_schedule):
                return
            # `shutdown -c` is the only cancel that reaches logind's CancelScheduledShutdown.
            # `systemctl cancel` must never be used here: since systemd ~258 the `cancel` verb
            # is the job-cancel verb (Manager.ClearJobs) — it exits 0 and leaves the schedule
            # file untouched, so exit-code checking alone reports success while a reboot stays
            # armed. That is exactly the production failure this loop exists to catch; the
            # schedule file, not any exit code, is the proof.
            self.run(["shutdown", "-c"], capture=True)
            time.sleep(2)
        if os.path.exists(self.shutdown_schedule):
            print("deploy-ai: warning: the guard reboot is still scheduled; run "
                  "`shutdown -c` on ai to stand it down", file=sys.stderr)

    # A deploy that only adds a port forward can leave qemu running the old command line: nothing
    # else in the unit changed, so activation never restarted it and the new forward goes nowhere.
    # Compare the installed unit's forwards with the live process and restart once on mismatch.
    def restart_stale_qemu(self) -> None:
        if self.dry_run:
            return
        show = self.run(["systemctl", "show", "buildvm.service", "-p", "MainPID", "-p",
                         "ExecStart"], capture=True)
        if show.returncode != 0:
            return
        fields = {}
        for line in show.stdout.splitlines():
            key, _, value = line.partition("=")
            fields.setdefault(key, value)
        want = set(re.findall(r"hostfwd=tcp:[^,\s]+", fields.get("ExecStart", "")))
        live = set()
        try:
            with open(f"/proc/{fields.get('MainPID', '0')}/cmdline", "rb") as handle:
                argv = handle.read().replace(b"\0", b" ").decode(errors="replace")
            live = set(re.findall(r"hostfwd=tcp:[^,\s]+", argv))
        except OSError:
            return
        if want and want != live:
            self.run(["systemctl", "restart", "buildvm.service"], capture=True)
            print("deploy-ai: buildvm.service restarted: its live command line lacked the "
                  f"installed port forwards ({sorted(want)})")

    def finish_ai_records(self, sha: str) -> None:
        # Called only once the new system is healthy, so the record simply claims it: a switch
        # that failed or rolled back never moves it.  The snapshots earlier gate versions kept
        # as rollback insurance have nothing left to protect — the boot pin is the rollback now.
        for name in ("commit", "toplevel"):
            try:
                os.remove(os.path.join(self.state, name + "-previous"))
            except OSError:
                pass
        # The switch is confirmed: provisioning already read `pending-commit` (if it ran at all),
        # and `commit` is the truth from here on.  A leftover pending file would mislead the next
        # provisioning on an out-of-band switch.
        try:
            os.remove(os.path.join(self.state, "pending-commit"))
        except OSError:
            pass
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
        print("deploy-ai: ai now")
        say("commit", short(deployed))
        # Truth, not memory: an out-of-band switch moves the system without moving the record,
        # and `--status` is asked precisely when something looks wrong.
        running = self.current_system()
        say("system", running)
        say("health", self.health_row())
        # The boot pin is the rollback: a default that is not the running entry means a reboot
        # takes ai back to that generation.
        default = self.boot_default_entry()
        entry = self.boot_entry_for(running)
        if default and default == entry:
            boot_row = "runs the running generation"
        elif default and "*" in default:
            # NixOS's own loader default: it picks the newest entry, which need not be the one
            # booted now — say so instead of calling the glob a pin.
            boot_row = "unpinned — a reboot boots the newest installed entry"
        elif default:
            boot_row = f"pinned to {default} — a reboot boots that generation"
        else:
            boot_row = "loader default unknown"
        say("boot", boot_row)
        say("guest", self.guest_row())
        base = self.effective_base()
        say("baseline", f"{base} "
                        f"{'(cached tree)' if base == self.base_cache else '(build-time source)'} "
                        f"{'(present)' if os.path.isdir(base) else '(missing)'}")
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

    # Whether the VM can be looked at at all.  `--status` answers questions about what is running, so a
    # key that is missing is something to report, not a reason to stop answering; the roads that deploy
    # still end over it in `need_guest_key`, because a deploy cannot converge the VM without it.
    def guest_key_absent(self) -> str:
        if not self.build_key:
            return f"no key to ssh into the VM as {BUILDER}; set {self.build_key_file}"
        if not os.access(self.build_key, os.R_OK):
            return f"{self.build_key} is not readable by uid {os.geteuid()}"
        return ""

    def guest_row(self) -> str:
        """What the guest runs, read from the guest.  `buildvm-provision` writes that file when it
        converges the VM onto ai's tree, so this is the VM's own answer rather than what ai hoped;
        a switch here does not mean the guest has converged yet."""
        absent = self.guest_key_absent()
        if absent:
            return "unknown, " + absent
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
        """Whether the timed reboot that catches a hung switch is still pending.  The logind
        schedule file is authoritative; the transient-timer property reads empty while a
        `reboot --when` is pending."""
        usec = ""
        try:
            with open(self.shutdown_schedule) as fh:
                for line in fh:
                    if line.startswith("USEC="):
                        usec = line.partition("=")[2].strip()
        except OSError:
            pass
        if not usec.isdigit():
            shown = self.run(["systemctl", "show", "reboot",
                              "--property=NextElapseSince1970Usec"], capture=True)
            usec = shown.stdout.partition("=")[2].strip()
        if usec.isdigit() and int(usec) > 0:
            when = datetime.datetime.fromtimestamp(int(usec) / 1_000_000).astimezone()
            return "reboot armed at " + when.isoformat(timespec="minutes")
        return "none armed"

    def switch_with_guards(self, sha: str) -> None:
        """The shared road: build, require the current system healthy, arm the guard, pin the
        boot default to the running generation, then hand the switch to a transient unit that
        confirms the new generation only once it becomes healthy."""
        current = self.current_system()
        self.record_rollback(current)

        # The current system must be healthy before a switch, or the switch hides an existing break.
        if not self.check_health():
            problems = self.health_problems()
            detail = ", ".join(problems) or f"the build VM at {BUILD_HOST}:{BUILD_PORT} is unreachable"
            die(f"the CURRENT system is already unhealthy ({detail}); switching would hide that.  "
                f"Fix it out-of-band or reboot {AI}")

        # Armed only now: a build that fails after an hour must not leave a reboot pending.
        self.arm_guard()
        if self.dry_run:
            # Nothing was switched, so nothing is recorded: a record claims what is live, and
            # `--status` would read a dry run as a deploy.
            self.do_switch()
            print("deploy-ai: nothing applied (--dry-run)")
            return

        # Pin the boot default to the RUNNING generation.  `switch` installs the new generation
        # as the boot default, and activation can sever the ssh session that started the gate —
        # so between the switch and the health confirmation below, any reboot boots the OLD
        # generation on its own.  The pin holds until the tail confirms it; nothing rewrites the
        # pin at boot, so a deploy that never confirmed leaves an old default and needs `--confirm-boot`.
        self.pin_boot(self.install_boot_entry(current))

        # Before the handoff, record the commit this switch converges onto.  Activation restarts
        # `buildvm-provision`, which runs *inside* this switch: a patch deploy carries no `self.rev`,
        # so without this the guest falls back to the commit it recorded last deploy and its record
        # names a stale commit forever.  The tail removes the file once the new system is recorded.
        pending = os.path.join(self.state, "pending-commit")
        with open(pending, "w", encoding="utf-8") as handle:
            handle.write(sha + "\n")

        # Everything after arm_guard runs as a transient systemd unit: the health wait, the boot
        # confirmation, the records, and the guard cancel finish even if this session dies.  A
        # death before the switch leaves the old generation live and pinned — nothing to undo.
        result = self.run(["systemd-run", "--unit=deploy-ai-switch", "--wait", "--collect",
                           gate_binary(sys.argv[0]),
                           "--switch-toplevel", self.toplevel, "--sha", sha])
        if result.returncode != 0:
            # systemd-run sends the unit's stdout to the journal, not back to --wait; without
            # this tail the operator sees only `exit 1` and has to go dig.
            unit_log = self.run(["journalctl", "--no-pager", "-u", "deploy-ai-switch", "-n", "60"],
                                capture=True)
            if unit_log.stdout:
                print(unit_log.stdout, file=sys.stderr, end="")
            fail(f"deploy of {sha} failed (switch unit exit {result.returncode}); check "
                 f"`journalctl -u deploy-ai-switch` and `deploy-ai --status`")

    def switch_tail(self, sha: str) -> int:
        """The post-arm_guard sequence, run inside the transient switch unit.  The records move
        only after health passes, so they claim what is live without snapshots or restores."""
        try:
            self.do_switch()
        except SystemExit:
            # The switch failed: the old generation is still live.  Pin it explicitly — `switch`
            # may have made the broken generation the boot default before failing.  Stand the
            # guard down only when the machine is demonstrably healthy; if activation broke
            # partway, the guard's own reboot is what walks ai back to the pinned generation.
            self.pin_boot(self.install_boot_entry(self.read_rollback_previous()))
            if self.check_health():
                self.cancel_guard()
            else:
                print("deploy-ai: the system is unhealthy after the failed switch; the boot pin "
                      "boots the previous generation and the reboot guard stays armed",
                      file=sys.stderr)
            raise
        if not self.wait_health():
            print("deploy-ai: the new system never became healthy; switching back", file=sys.stderr)
            self.pin_boot(self.install_boot_entry(self.read_rollback_previous()))
            if not self.rollback():
                # Even the switch-back broke.  A broken machine with the guard cancelled recovers
                # only when someone reboots into the pinned entry, so keep the guard armed and
                # say so instead of reporting a rollback that did not happen.
                fail(f"deploy of {sha} failed and the switch-back also failed; the boot pin boots "
                     f"the previous generation and the reboot guard stays armed; "
                     f"log: {os.path.join(self.state, 'log', 'build.log')}")
            self.cancel_guard()
            fail(f"deploy of {sha} failed and was rolled back; log: {os.path.join(self.state, 'log', 'build.log')}")
        self.confirm_boot()
        self.finish_ai_records(sha)
        self.cancel_guard()
        self.restart_stale_qemu()
        print(f"deploy-ai: ai is now running {sha} ({self.toplevel})")
        return 0

    # `git archive` streams the commit's tree; `tar` needs somewhere to unpack it, and a bare mirror
    # has no worktree, so both directions go through a temporary directory.
    def archive_dir(self, sha: str) -> str:
        dest = tempfile.mkdtemp(prefix="deploy-ai-archive.")
        pack = subprocess.Popen(["git", "--git-dir", self.mirror, "archive", "--format=tar", sha],
                                stdout=subprocess.PIPE)
        unpack = self.run(["tar", "x", "-C", dest], stdin=pack.stdout)
        pack.stdout.close()
        # git's exit code is load-bearing: on a missing commit it writes no tar at all, and `tar x`
        # reads EOF and exits 0 — checking only the unpack would hand back an empty tree that the
        # deploy then builds into nothing.
        archived = pack.wait()
        if archived != 0 or unpack.returncode != 0:
            shutil.rmtree(dest, ignore_errors=True)
            fail(f"cannot unpack {sha} from {self.mirror}")
        return dest

    def unpack_local_tar(self, tree: str, dest: str, *, exclude_git: bool = False) -> None:
        pack = subprocess.Popen(["tar", "-C", tree] + (["--exclude=.git"] if exclude_git else [])
                                + ["-cf", "-", "."], stdout=subprocess.PIPE)
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
        trusted = self.trust_match()
        self.check_history(base, trusted=bool(trusted))

        self.acquire_lock()
        work = tempfile.mkdtemp(prefix="deploy-ai-tree.")
        try:
            self.unpack_local_tar(self.archive_dir(self.sha), work)
            if trusted:
                say("trust", f"{trusted}: merge-reviewed tip; the allowlist is not applied")
            else:
                self.check_scope(work)
            # The same road a submission takes: build it here, and re-evaluate the same source, so the
            # path being switched is one ai derived twice.
            self.apply_on_ai(work, self.sha)
            if not self.dry_run:
                self.cache_base_tree(work)
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
        src = self.effective_base()
        if not os.path.isdir(src):
            die(f"{src} is missing; the running system was built without "
                f"nixflakes.deploy-ai.deployedSource")
        pack = subprocess.Popen(["tar", "-C", src, "-cf", "-", "."], stdout=subprocess.PIPE)
        unpack = self.run(["tar", "-x", "-C", dest], stdin=pack.stdout)
        pack.stdout.close()
        pack.wait()
        if unpack.returncode != 0:
            fail(f"cannot copy {src} into {dest}")
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

    # Every submission takes this road, including one that only changes the build VM's own files: ai
    # runs the api server, so ai is what has to be healthy, and the guest picks the change up when
    # provisioning rebuilds it from the tree this switch put in place.
    def apply_on_ai(self, tree: str, sha: str) -> None:
        view = self.build_view(tree)
        try:
            self.build_on_ai(view)
            self.verify_output(AI, self.toplevel, view)
        finally:
            if view != tree:
                shutil.rmtree(view, ignore_errors=True)
        self.switch_with_guards(sha)

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
            for path in self.changed_paths(work):
                say("changed", path)

            if self.vet_only or self.dry_run:
                say("would", "build on ai, switch ai, and reboot back if it never becomes healthy")
                print(f"deploy-ai: nothing applied ({'--vet' if self.vet_only else '--dry-run'})")
                return "ok"
            self.apply_on_ai(work, self.sha)
            self.cache_base_tree(work)
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
    parser.add_argument("--switch-toplevel", default="")
    parser.add_argument("--sha", default="")
    parser.add_argument("--confirm-boot", action="store_true")
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

    if args.switch_toplevel:
        # Re-entry point of the transient switch unit armed by a real deploy
        # (see switch_with_guards): the tail must finish even if the ssh session
        # that started the deploy dies during activation.
        tool.need()
        tool.toplevel = args.switch_toplevel
        if not args.sha:
            print(USAGE, file=sys.stderr)
            return 1
        tool.sha = args.sha
        tool.switch_tail(args.sha)
        return 0

    if args.confirm_boot:
        tool.need()
        tool.confirm_boot()
        print("result: ok")
        return 0
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
