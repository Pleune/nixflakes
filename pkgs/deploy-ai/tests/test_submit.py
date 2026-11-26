"""The submit road end to end: stdin patch, reconstruction, the gate rows, the refusals.

The patch is a real `git format-patch` of a real commit, reconstructed onto a real baseline
copy -- the trust model (nothing from the guest's tree or history is taken) is exercised,
not asserted with stubs.
"""

import io
import os
import shutil
import subprocess
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path

from support import DeployWorld, captured, patch_input, refusal, row


class TestSubmitRoad(DeployWorld):
    def setup_method(self):
        super().setup_method(DEPLOY_AI_ALLOWLIST="platforms/\npkgs/\n",
                             DEPLOY_AI_DENY_FILE="pkgs/deploy-ai/\n",
                             DEPLOY_AI_SUBMIT_MAX_BYTES_FILE="10000",
                             DEPLOY_AI_POLICY_FILE="abc123")
        self.tool.vet_only = False   # main sets this per verb; scenarios say which one they run
        self.repo, self.deployed = self.origin(
            **{"flake.nix": "{}\n", "platforms/buildvm.nix": "one\n"})

    def patch_of(self, sha: str) -> bytes:
        return subprocess.run(["git", "-C", self.repo, "format-patch", "-1", "--stdout", sha],
                              capture_output=True, check=True).stdout

    def submit(self, patch: bytes):
        out, err = io.StringIO(), io.StringIO()
        verdict = None
        with patch_input(patch), redirect_stdout(out), redirect_stderr(err):
            try:
                verdict = self.tool.do_submit()
            except SystemExit:
                pass
        return verdict, out.getvalue(), err.getvalue()

    def test_a_patch_reconstructs_deploys_and_the_records_name_one_host_commit(self):
        sha = self.revise(self.repo, **{"platforms/buildvm.nix": "two\n"})
        patch = self.patch_of(sha)
        verdict, out, _ = self.submit(patch)
        assert (verdict == "applied")
        assert ("applies" in out and "scope" in out and "denylist" in out)
        assert (row("policy", "unchanged") in out)
        assert (row("changed", "platforms/buildvm.nix") in out)
        # The reconstructed commit is the host's own and is retained, because no repository
        # anywhere else contains it.
        recorded = self.tool.sha
        assert (recorded != sha)  # guest metadata is not trusted: one host-authored commit
        resolved = subprocess.run(["git", "--git-dir", os.path.join(self.tool.state, "base.git"),
                                   "rev-parse", "HEAD"], capture_output=True, text=True)
        assert (resolved.stdout.strip() == recorded)
        assert (Path(self.tool.state, "commit").read_text().strip() == recorded)
        assert ("default nixos-new.conf" in Path(self.tool.boot_conf).read_text())
        # The tree that was built carries no `.git`: the reconstruction's history stays local.
        assert (all(".git" not in listing for _tree, listing in self.build_calls))

    def test_a_vet_reports_the_road_without_taking_it(self):
        sha = self.revise(self.repo, **{"platforms/buildvm.nix": "two\n"})
        self.tool.vet_only = True
        verdict, out, _ = self.submit(self.patch_of(sha))
        assert (verdict == "ok")
        assert ("nothing applied" in out)
        assert ("would" in out)
        assert (not self.build_calls)
        assert (not self.saw("systemd-run"))
        assert (Path(self.tool.state, "commit").read_text().strip() == self.deployed)

    def test_a_patch_outside_the_allowlist_refuses_after_the_rows_that_held(self):
        sha = self.revise(self.repo, **{"modules/nixos/x.nix": "x\n"})
        verdict, out, err = self.submit(self.patch_of(sha))
        assert (verdict is None)
        assert ("modules/nixos/x.nix" in err and "outside the deploy-ai allowlist" in err)
        assert ("result: refused" in err)
        # Rows land in order: the checks that passed printed, the one that refused did not.
        assert ("applies" in out and "scope" not in out)

    def test_a_patch_touching_the_gate_refuses_even_inside_the_allowlist(self):
        sha = self.revise(self.repo, **{"pkgs/deploy-ai/deploy-ai.py": "sneaky\n"})
        verdict, out, err = self.submit(self.patch_of(sha))
        assert (verdict is None)
        assert ("pkgs/deploy-ai/deploy-ai.py" in err)
        assert ("scope" in out and "denylist" not in out)  # scope held; the denylist refused

    def test_a_patch_that_moves_the_policy_is_refused_as_out_of_band(self):
        sha = self.revise(self.repo, **{"platforms/buildvm.nix": "two\n"})
        self.policy = "zzz"   # the candidate tree evaluates a different digest than ai enforces
        verdict, _out, err = self.submit(self.patch_of(sha))
        assert (verdict is None)
        assert ("changes the deployment policy" in err)
        assert ("out-of-band" in err)
        assert (not self.build_calls)

    def test_a_stale_patch_names_the_baseline_it_should_rebase_onto(self):
        sha = self.revise(self.repo, **{"platforms/buildvm.nix": "two\n"})
        patch = self.patch_of(sha)
        Path(self.tool.baseline, "platforms/buildvm.nix").write_text("drifted\n")
        verdict, _out, err = self.submit(patch)
        assert (verdict is None)
        assert ("does not apply to the deployed commit" in err)
        assert (self.deployed[:8] in err)  # the refusal carries the commit to rebase onto

    def test_an_oversized_empty_or_uncapped_patch_refuses_on_arrival(self):
        with refusal() as message:
            with patch_input(b""):
                self.tool.save_incoming_patch()
        assert ("empty patch on stdin" in message.getvalue())
        Path(self.tool.submit_max_bytes_file).write_text("10\n")
        self.tool.submit_max_bytes_raw = "10"
        with refusal() as message:
            with patch_input(b"x" * 11):
                self.tool.save_incoming_patch()
        assert ("patch too large" in message.getvalue() and "over the 10 limit" in message.getvalue())
        Path(self.tool.submit_max_bytes_file).write_text("many\n")
        self.tool.submit_max_bytes_raw = "many"
        with refusal() as message:
            with patch_input(b"x"):
                self.tool.save_incoming_patch()
        assert ("does not hold an integer" in message.getvalue())

    def test_a_machine_built_without_the_deployed_source_refuses_to_reconstruct(self):
        sha = self.revise(self.repo, **{"platforms/buildvm.nix": "two\n"})
        shutil.rmtree(self.tool.baseline)
        verdict, _out, err = self.submit(self.patch_of(sha))
        assert (verdict is None)
        assert ("deployedSource" in err)


class TestDeployedBaseCache(DeployWorld):
    """Patches apply onto what is deployed, not the build-time source.

    `deployed-source` is written when the system is built and never moves, so after a deploy
    the recorded source describes an older tree.  Every successful deploy therefore caches
    the tree it landed, and the next patch rebased onto the deployed commit must apply onto
    that cache even when the build-time source has drifted.
    """

    def setup_method(self):
        super().setup_method(DEPLOY_AI_ALLOWLIST="platforms/\n",
                             DEPLOY_AI_DENY_FILE="pkgs/deploy-ai/\n",
                             DEPLOY_AI_SUBMIT_MAX_BYTES_FILE="10000",
                             DEPLOY_AI_POLICY_FILE="abc123")
        self.tool.vet_only = False
        self.repo, self.deployed = self.origin(
            **{"flake.nix": "{}\n", "platforms/buildvm.nix": "one\n"})
        mirror = os.path.join(self.root, "mirror.git")
        subprocess.run(["git", "clone", "--bare", "--quiet", self.repo, mirror], check=True)
        self.tool.mirror = mirror

    def patch_of(self, sha: str) -> bytes:
        return subprocess.run(["git", "-C", self.repo, "format-patch", "-1", "--stdout", sha],
                              capture_output=True, check=True).stdout

    def submit(self, patch: bytes):
        out, err = io.StringIO(), io.StringIO()
        verdict = None
        with patch_input(patch), redirect_stdout(out), redirect_stderr(err):
            try:
                verdict = self.tool.do_submit()
            except SystemExit:
                pass
        return verdict, out.getvalue(), err.getvalue()

    def deploy(self, ref="main"):
        self.tool.repo = self.repo
        self.tool.ref = ref
        out, err = io.StringIO(), io.StringIO()
        verdict = None
        with redirect_stdout(out), redirect_stderr(err):
            try:
                verdict = self.tool.do_deploy()
            except SystemExit:
                pass
        return verdict, out.getvalue(), err.getvalue()

    def test_a_submit_caches_its_tree_and_the_next_submit_stacks_on_it(self):
        first = self.revise(self.repo, **{"platforms/buildvm.nix": "two\n"})
        assert (self.submit(self.patch_of(first))[0] == "applied")
        assert (os.path.isdir(self.tool.base_cache))
        # The build-time source drifts -- the very state a gate deploy leaves behind.
        Path(self.tool.baseline, "platforms/buildvm.nix").write_text("one\n")
        second = self.revise(self.repo, **{"platforms/buildvm.nix": "three\n"})
        verdict, out, err = self.submit(self.patch_of(second))
        assert (verdict == "applied"), err
        assert (row("changed", "platforms/buildvm.nix") in out)
        # The cache now holds the second tree, and it -- not the drifted source -- is what
        # `--status` reports as the patch base.
        assert (Path(self.tool.base_cache, "platforms/buildvm.nix").read_text() == "three\n")
        assert (row("baseline", f"{self.tool.base_cache} (cached tree) (present)") in
               captured(self.tool.do_status))

    def test_a_repo_deploy_refreshes_the_base_the_next_patch_applies_onto(self):
        tip = self.revise(self.repo, **{"platforms/buildvm.nix": "two\n"})
        verdict, _out, err = self.deploy()
        assert (verdict == "applied"), err
        # The flake source is still the pre-deploy tree; a patch rebased onto the deployed
        # tip must apply onto the cached tree the deploy left behind.
        Path(self.tool.baseline, "platforms/buildvm.nix").write_text("one\n")
        next_tip = self.revise(self.repo, **{"platforms/buildvm.nix": "three\n"})
        verdict, _out, err = self.submit(self.patch_of(next_tip))
        assert (verdict == "applied"), err
        assert (Path(self.tool.base_cache, "platforms/buildvm.nix").read_text() == "three\n")
