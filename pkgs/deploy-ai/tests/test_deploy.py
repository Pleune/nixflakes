"""The deploy road end to end: fetch, guards, build, switch, pin, records, rollback.

Each scenario drives a whole verb (`do_deploy`, `switch_with_guards`) through the simulated host
and asserts the state that landed plus the argv contract in `world.calls` -- what the machine was
asked to run.  Git really fetches, archives, and diffs; only the machine is simulated.
"""

import io
import os
import subprocess
import sys
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path

import pytest

from support import DeployWorld, World, outcome, refusal


class TestDeployRoad(DeployWorld):
    def setup_method(self):
        super().setup_method(DEPLOY_AI_ALLOWLIST="platforms/\nflake.lock\n")
        self.repo, self.deployed = self.origin(
            **{"flake.nix": "{}\n", "platforms/buildvm.nix": "one\n"})

    def deploy(self, ref="main"):
        """Run the deploy verb whole, capturing both streams; a refusal yields no verdict."""
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

    def test_a_full_deploy_lands_records_the_pin_and_the_guard(self):
        sha = self.revise(self.repo, **{"platforms/buildvm.nix": "two\n"})
        verdict, out, _ = self.deploy()
        assert (verdict == "applied")
        assert (self.saw("--git-dir") and self.saw("fetch"))
        assert (self.saw("nix build"))
        # The build shares ai with the api server, so it must be capped, not nix's own default.
        assert (self.saw("--max-jobs 2"))
        assert (self.saw("systemctl reboot --when +60m"))  # the guard, armed before the switch
        assert (self.saw("systemd-run --unit=deploy-ai-switch --wait --collect"))
        assert (self.saw("--switch-toplevel /nix/store/new-system"))
        assert (self.saw("systemctl cancel"))            # stood down once health passed
        assert (not self.saw("systemctl cancel --when")) # cancel takes no option; that's a usage error
        assert (not os.path.exists(self.schedule_path))  # logind's file gone: no reboot pending
        # The guest's provisioning runs inside this switch: the handoff must carry the commit,
        # and the record must be gone once the new system is recorded.
        assert (self.pending_at_switch == sha)
        assert (not os.path.exists(Path(self.tool.state, "pending-commit")))
        assert ("ai is now running" in out)
        # What is live: the records, and the boot pin that points at the running generation.
        assert (Path(self.tool.state, "commit").read_text().strip() == sha)
        assert (Path(self.tool.state, "toplevel").read_text().strip() == self.TOPLEVEL)
        assert (sha in Path(self.tool.state, "refs.log").read_text())
        assert ("default nixos-new.conf" in Path(self.tool.boot_conf).read_text())

    def test_a_cancel_rejected_by_a_mid_switch_logind_restart_is_retried(self):
        # The production failure: a switch activation restarts dbus/logind just as the tail
        # cancels the guard, so the first cancels fail; a swallowed one left ai scheduled to
        # reboot an hour later while `--status` read "none armed".
        self.cancel_failures = 2
        self.revise(self.repo, **{"platforms/buildvm.nix": "two\n"})
        verdict, _, _ = self.deploy()
        assert (verdict == "applied")
        assert (self.calls.count("systemctl cancel") == 3)
        assert (not os.path.exists(self.schedule_path))

    def test_a_guard_that_cannot_be_stood_down_says_so(self):
        # Beyond the retries the reboot really is pending; the deploy must warn instead of
        # pretending, and `--status` must report it from logind's file.
        self.cancel_failures = 99
        self.revise(self.repo, **{"platforms/buildvm.nix": "two\n"})
        verdict, _, err = self.deploy()
        assert (verdict == "applied")
        assert ("still scheduled" in err)
        assert ("reboot armed at" in self.tool.guard_row())

    def test_a_host_with_no_entries_links_profiles_and_installs_entries(self):
        # The ai reproduction: a deploy builds `--no-link`, so no system profile exists, and
        # systemd-boot's installer writes nothing without profiles -- every pin found no entry.
        # The deploy must link each generation it pins, then the installer produces entries.
        sha = self.revise(self.repo, **{"platforms/buildvm.nix": "two\n"})
        os.remove(Path(self.tool.boot_entries, "nixos-old.conf"))
        os.remove(Path(self.tool.boot_entries, "nixos-new.conf"))
        verdict, _out, _err = self.deploy()
        assert (verdict == "applied")
        assert (self.saw("switch-to-configuration boot"))
        assert (self.profile_links == [self.gen_old, self.TOPLEVEL])
        assert ("default nixos-new.conf" in Path(self.tool.boot_conf).read_text())
        assert (f"init={self.TOPLEVEL}/init" in Path(self.tool.boot_entries, "nixos-new.conf").read_text())

    def test_a_build_that_fails_switches_nothing_and_says_failed(self):
        self.revise(self.repo, **{"platforms/buildvm.nix": "two\n"})
        self.build_rc = 1
        verdict, _out, err = self.deploy()
        assert (verdict is None)
        assert ("build failed on ai" in err)
        assert ("result: failed" in err)
        assert (not self.saw("systemd-run"))
        assert (Path(self.tool.state, "commit").read_text().strip() == self.deployed)

    def test_a_current_system_that_is_already_unhealthy_refuses_before_armed(self):
        self.revise(self.repo, **{"platforms/buildvm.nix": "two\n"})
        self.healthy = False
        self.curl_code = "503"
        verdict, _out, err = self.deploy()
        assert (verdict is None)
        assert ("CURRENT system is already unhealthy" in err)
        assert ("hermes-agent inactive" in err and "health endpoint answered 503" in err)
        # A refusal that hides an existing break must not arm anything or switch anything; the
        # build may already have run, but nothing on the system changes.
        assert (not self.saw("reboot --when"))
        assert (not self.saw("systemd-run"))
        assert (Path(self.tool.state, "commit").read_text().strip() == self.deployed)

    def test_a_new_system_that_never_becomes_healthy_switches_back(self):
        self.revise(self.repo, **{"platforms/buildvm.nix": "two\n"})
        self.after_switch_healthy = False   # the units go dead with the new activation
        verdict, _out, err = self.deploy()
        assert (verdict is None)
        assert ("never became healthy; switching back" in err)
        assert ("was rolled back" in err)
        # The rollback is real: the old generation's switcher ran, the pin points back at it,
        # and the records still claim what is live -- the old system.
        assert (self.saw(os.path.join(self.gen_old, "bin", "switch-to-configuration") + " switch"))
        assert ("default nixos-old.conf" in Path(self.tool.boot_conf).read_text())
        assert (Path(self.tool.state, "commit").read_text().strip() == self.deployed)
        assert (Path(self.tool.state, "toplevel").read_text().strip() == self.gen_old)
        assert ("result: failed" in err)

    def test_a_switch_back_that_also_breaks_on_an_unwell_host_keeps_the_guard(self):
        self.revise(self.repo, **{"platforms/buildvm.nix": "two\n"})
        self.after_switch_healthy = False   # dead after the switch *and* after the switch-back
        self.rollback_rc = 3
        verdict, _out, err = self.deploy()
        assert (verdict is None)
        assert ("never became healthy; switching back" in err)
        assert ("the rollback switch exited 3" in err)
        assert ("switch-back also failed" in err)
        # A broken machine with no working rollback keeps its reboot insurance.
        assert (not self.saw("systemctl cancel --when"))

    def test_a_dry_run_reports_the_switch_and_claims_nothing(self):
        self.revise(self.repo, **{"platforms/buildvm.nix": "two\n"})
        self.tool.dry_run = True
        verdict, out, _ = self.deploy()
        assert (verdict == "ok")
        assert ("would switch ai to" in out)
        assert (not self.saw("reboot --when"))
        assert (not self.saw("systemd-run"))
        # Records say a deploy landed; a dry run must not print one that never happened.
        assert (not os.path.exists(os.path.join(self.tool.state, "refs.log")))

    def test_a_change_outside_the_allowlist_is_named_with_where_it_may_go(self):
        self.revise(self.repo, **{"modules/nixos/x.nix": "x\n"})
        verdict, _out, err = self.deploy()
        assert (verdict is None)
        assert ("modules/nixos/x.nix" in err)
        assert ("outside the deploy-ai allowlist" in err)
        assert ("platforms/" in err)  # the refusal names where the change is allowed
        assert (not self.saw("nix build"))

    def test_a_candidate_that_rewrites_history_is_refused(self):
        self.revise(self.repo, **{"platforms/buildvm.nix": "two\n"})
        subprocess.run(["git", "-C", self.repo, "checkout", "-q", "--orphan", "lost"], check=True)
        self.revise(self.repo, **{"flake.nix": "{}\n"})
        subprocess.run(["git", "-C", self.repo, "checkout", "-q", "main"], check=True)
        verdict, _out, err = self.deploy(ref="lost")
        assert (verdict is None)
        assert ("does not have the deployed commit" in err)
        assert (not self.saw("nix build"))

    def test_a_base_the_mirror_never_saw_falls_back_then_degrades_to_a_skip(self):
        self.revise(self.repo, **{"platforms/buildvm.nix": "two\n"})
        # A gate-deployed commit lives only in ai's retained base, not in the mirror being fetched:
        # the check falls back to the recorded flake commit...
        Path(self.tool.state, "commit").write_text("f" * 40 + "\n")
        verdict, _out, err = self.deploy()
        assert (verdict == "applied")
        assert ("checking history against" in err)
        # ...and with neither commit known, it says it skipped instead of refusing a legit deploy.
        Path(self.tool.baseline_commit_file).write_text("")
        Path(self.tool.state, "commit").write_text("e" * 40 + "\n")
        verdict, _out, err = self.deploy(ref="main")
        assert (verdict == "applied")
        assert ("descendant check is skipped" in err)


class TestTrust(DeployWorld):
    HOST = "https://git.pleunetowne.com/mitchpleune/nixflakes.git"

    def setup_method(self):
        super().setup_method(DEPLOY_AI_ALLOWLIST="platforms/\n")
        self.repo, _deployed = self.origin(
            **{"flake.nix": "{}\n", "platforms/buildvm.nix": "one\n"})
        self.tip = self.revise(self.repo, **{"platforms/buildvm.nix": "two\n"})
        mirror = os.path.join(self.root, "mirror.git")
        subprocess.run(["git", "clone", "--bare", "--quiet", self.repo, mirror], check=True)
        self.tool.mirror = mirror

    def trusted_as(self, repo_url: str, sha: str, entries: str | None = None) -> str:
        self.tool.repo = repo_url
        self.tool.sha = sha
        if entries is not None:
            Path(self.tool.trusted_file).write_text(entries)
        subprocess.run(["git", "--git-dir", self.tool.mirror, "fetch", "--quiet", "origin",
                        "+refs/heads/*:refs/heads/*"], check=True)
        return self.tool.trust_match()

    def test_a_tip_of_a_trusted_branch_is_trusted_whatever_url_form_it_arrives_in(self):
        # Identity is scheme-, credentials-, and port-blind, so ssh and https forms are one repo.
        Path(self.tool.trusted_file).write_text(self.HOST + "\tmain\n")
        assert (self.trusted_as("ssh://git@git.pleunetowne.com:2223/mitchpleune/nixflakes.git",
                                self.tip))
        assert (self.trusted_as(self.HOST, self.tip))
        # A commit behind the tip is not trusted -- trust applies to exactly the merge head.
        assert (self.trusted_as(self.HOST, "b" * 40) == "")
        # A repository on the VM has its own unreviewed main and is never trusted.
        assert (self.trusted_as("ssh://builder@127.0.0.1:2224/home/builder/nixflakes", self.tip)
                == "")

    def test_a_trusted_tip_skips_the_allowlist_and_an_untrusted_one_does_not(self):
        tip = self.revise(self.repo, **{"modules/nixos/x.nix": "x\n"})
        # The same commit outside the allowlist: refused alone, deployable when its branch tip
        # is listed as a trusted source.
        assert (self.trusted_as(self.repo, tip) == "")
        assert (self.trusted_as(self.repo, tip, entries=f"{self.repo}\tmain\n"))


class TestGuestAndLock(World):
    def test_a_guest_repo_deploy_refuses_over_a_missing_key_before_any_fetch(self):
        tool = self.tool
        os.remove(tool.build_key)
        tool.repo = "ssh://builder@127.0.0.1:2224/home/builder/nixflakes"
        with refusal() as message:
            tool.ensure_mirror()
        assert ("not readable" in message.getvalue())
        assert (not self.saw("fetch"))

    def test_a_gate_killed_mid_deploy_does_not_lock_the_deployer_out(self):
        tool = self.tool
        lock = os.path.join(tool.state, "lock")
        os.mkdir(lock)
        Path(lock, "pid").write_text("999999\n")  # a dead holder: activation severed the session
        tool.acquire_lock()
        tool.release_lock()
        assert (not os.path.isdir(lock))

    def test_a_live_deployer_still_holds_the_lock(self):
        holder = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(120)  # deploy-ai"])
        try:
            tool = self.tool
            lock = os.path.join(tool.state, "lock")
            os.mkdir(lock)
            Path(lock, "pid").write_text(f"{holder.pid}\n")
            with refusal() as message:
                tool.acquire_lock()
            assert ("another deploy-ai is running" in message.getvalue())
        finally:
            holder.kill()
            holder.wait()


class TestSwitchTail(World):
    def test_a_switch_unit_that_fails_reports_the_exit_and_changes_nothing(self):
        tool = self.tool
        tool.toplevel = self.TOPLEVEL
        Path(tool.state, "commit").write_text("a" * 40 + "\n")
        Path(tool.state, "toplevel").write_text(self.gen_old + "\n")
        self.tail_rc = 2
        with outcome() as message:
            tool.switch_with_guards("b" * 40)
        assert ("switch unit exit 2" in message.getvalue())
        # The tail never ran: nothing switched, the pin still holds the running generation.
        assert (self.running == self.gen_old)
        assert ("default nixos-old.conf" in Path(tool.boot_conf).read_text())
        assert (Path(tool.state, "commit").read_text().strip() == "a" * 40)

    def test_a_failed_activation_repins_the_old_generation_and_keeps_the_guard(self):
        tool = self.tool
        tool.toplevel = self.TOPLEVEL
        Path(tool.state, "commit").write_text("a" * 40 + "\n")
        Path(tool.state, "toplevel").write_text(self.gen_old + "\n")
        self.switch_rc = 1                    # switch-to-configuration itself broke mid-activate
        self.after_switch_healthy = False     # the machine stays dead after it
        out, err = io.StringIO(), io.StringIO()
        with redirect_stdout(out), redirect_stderr(err):
            try:
                tool.switch_with_guards("b" * 40)
            except SystemExit:
                pass
        assert ("unhealthy after the failed switch" in err.getvalue())
        assert ("switch unit exit 1" in err.getvalue())
        # The activation broke halfway, so the guard's own reboot is the rollback: it stays armed,
        # and the pin was moved back to the previous generation.
        assert (not self.saw("systemctl cancel --when"))
        assert ("default nixos-old.conf" in Path(tool.boot_conf).read_text())
