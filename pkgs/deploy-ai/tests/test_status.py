"""The status screen: one scenario per kind of host truth it has to tell straight.

`--status` is asked precisely when something looks wrong, so the interesting cases are the
lies it must not tell: a stale record vs. the running system, a pin that points elsewhere,
a guest it cannot reach, a guard still armed.
"""

import os
from pathlib import Path

from support import World, captured, row


class TestStatusRoad(World):
    def setup_method(self):
        super().setup_method()
        self.ssh_out = "b" * 40 + "\n"     # the VM reports what it was provisioned with

    def screen(self) -> str:
        return captured(self.tool.do_status)

    def test_a_healthy_pinned_host_reports_every_row_from_live_truth(self):
        Path(self.tool.state, "commit").write_text("a" * 40 + "\n")
        Path(self.tool.state, "refs.log").write_text(
            "2026-11-24T10:00:00Z\t" + "a" * 40 + "\tdeploy main\n")
        self.tool.set_loader_default("nixos-old.conf")   # the pin matches what runs
        self.guard = str(10 ** 12)                       # a timed reboot really pending
        screen = self.screen()
        assert ("  commit" in screen and "a" * 8 in screen)
        assert (self.running in screen)                  # the running generation, not the record
        assert (row("health", "ok") in screen)
        assert (row("boot", "runs the running generation") in screen)
        assert ("b" * 8 in screen)                       # the guest's own answer
        assert ("(present)" in screen)
        assert ("none armed" not in screen and "reboot armed at" in screen)
        assert ("deploy main" in screen)

    def test_a_down_host_says_what_is_down_in_words_a_reader_can_act_on(self):
        self.healthy = False
        self.curl_code = "503"
        assert ("down: hermes-agent inactive" in self.screen())
        assert ("health endpoint answered 503" in self.screen())

    def test_a_record_stale_by_an_out_of_band_switch_does_not_drive_the_screen(self):
        Path(self.tool.state, "commit").write_text("a" * 40 + "\n")
        self.running = self.sibling("gen-other")         # someone switched behind the gate's back
        assert (self.running in self.screen())

    def test_the_boot_pin_row_distinguishes_a_pin_from_nixos_own_newest_default(self):
        self.tool.set_loader_default("nixos-new.conf")   # pin names another generation
        assert ("pinned to nixos-new.conf" in self.screen())
        Path(self.tool.boot_conf).write_text("default nixos-*\n")  # systemd-boot's glob default
        assert ("unpinned" in self.screen())

    def test_an_unreachable_guest_is_reported_not_fatal(self):
        self.ssh_rc = 255
        assert ("unknown, ssh to the VM failed" in self.screen())
        os.remove(self.tool.build_key)
        assert ("unknown," in self.screen() and "not readable" in self.screen())
        self.tool.build_key = ""
        assert ("no key to ssh" in self.screen())

    def test_a_fresh_host_reports_the_absences_instead_of_inventing_history(self):
        screen = self.screen()
        assert ("none recorded" in screen)               # no refs.log yet
        assert ("loader default unknown" in screen or "unpinned" in screen)
