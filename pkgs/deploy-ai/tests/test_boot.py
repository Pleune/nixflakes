"""The boot pin: the rollback is a loader default, so its files are the contract.

Entries are real files in a fake ESP; a scenario asserts what loader.conf ends up saying,
because that is exactly what a reboot will obey.
"""

import io
import os
from contextlib import redirect_stderr
from pathlib import Path

from support import World, refusal


class TestBootRoad(World):
    def setup_method(self):
        super().setup_method(DEPLOY_AI_ALLOWLIST="platforms/\n",
                             DEPLOY_AI_POLICY_FILE="abc123")

    def test_confirm_boot_points_the_next_boot_at_what_is_running(self):
        self.boot_installs = False            # an entry already names the running generation
        self.tool.confirm_boot()
        assert ("default nixos-old.conf" in Path(self.tool.boot_conf).read_text())
        assert (not self.saw("switch-to-configuration"))

    def test_a_boot_that_installs_an_entry_pins_the_newest_generation(self):
        self.boot_installs = True             # `boot` fabricates the entry, as NixOS does
        self.running = self.sibling("gen-unbooted")   # nothing in the ESP names this one yet
        self.tool.confirm_boot()
        assert ("default nixos-new.conf" in Path(self.tool.boot_conf).read_text())
        assert (self.saw("bin/switch-to-configuration boot"))

    def test_a_loader_that_refuses_to_say_which_generation_rejects_the_confirm(self):
        self.boot_installs = False
        self.running = self.sibling("gen-unlisted")   # no entry and `boot` installs none
        with refusal() as message:
            self.tool.confirm_boot()
        assert ("nothing to confirm" in message.getvalue())

    def test_an_unwritable_loader_conf_is_a_failure_not_a_silent_pin(self):
        self.boot_installs = False
        os.remove(self.tool.boot_conf)
        os.mkdir(self.tool.boot_conf)   # a directory where a file belongs: any replace fails
        try:
            with refusal() as message:
                self.tool.confirm_boot()
        finally:
            os.rmdir(self.tool.boot_conf)
        assert ("could not write the loader default" in message.getvalue())

    def test_the_rollback_switches_back_to_the_recorded_previous_generation(self):
        Path(self.tool.state, "rollback-previous").write_text(self.gen_old + "\n")
        assert (self.tool.rollback() is True)
        assert (self.running == self.gen_old)

    def test_a_rollback_with_no_recorded_target_leaves_the_machine_alone(self):
        err = io.StringIO()
        with redirect_stderr(err):
            assert (self.tool.rollback() is False)   # the guard's reboot is the rollback then
        assert ("no rollback target recorded" in err.getvalue())
        assert (self.running == self.gen_old)
