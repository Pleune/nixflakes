{ pkgs, inputs }:

# VM-level validation for the deploy-ai module and gate, wired into flake.nix's `checks`.
#
# These deriveations *run* qemu during their build, so they need a machine with qemu and KVM:
# ai itself, git-runner1, or any host with nested virt.  `nix build .#checks.x86_64-linux.<name>`
# on such a host exercises the whole thing; the build VM guest cannot run them (no qemu there).
#
# They live with the module they exercise, the way the buildvm platform's boot check lives at
# modules/nixos/virtualisation/buildvm/tests/.  The pytest unit suite, by contrast, tests the
# deploy *package* and stays at pkgs/deploy-ai/tests/.
#
# Both systems here are mini systems defined in this directory, built only from the deploy
# package plus `./test-options.nix` -- deliberately NOT the real platform configs, so these
# checks test the module and package themselves and nothing the platform happens to add.
{
  deploy-ai-gate-boot = import ./gate-boot.nix {
    testers = pkgs.testers;
    inherit pkgs;
  };

  deploy-ai-live-deploy = import ./live-deploy.nix {
    testers = pkgs.testers;
    inherit pkgs inputs;
  };
}
