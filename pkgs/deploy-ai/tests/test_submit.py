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

from support import DeployWorld, patch_input, refusal, row


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
