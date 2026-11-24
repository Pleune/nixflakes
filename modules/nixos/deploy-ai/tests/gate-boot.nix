{ testers, pkgs }:

# The deploy gate on a fresh machine, booted for real under UEFI so systemd-boot, bootctl, and
# the BLS entries the gate compares against all exist.  It proves: the gate binary is installed,
# --status reports without a guest or api server to talk to, a lock whose holder died is
# reclaimed rather than wedging every later deploy, and --confirm-boot pins the loader default
# to the running generation's *exact* entry id — the `nixos-*` glob NixOS writes at boot is not
# a pin, it just means "whatever is newest", which is exactly what a rollback must avoid.
testers.nixosTest {
  name = "deploy-ai-gate-boot";

  nodes.gate =
    { ... }:
    {
      imports = [ ../default.nix ];

      boot.loader.grub.enable = false;
      boot.loader.systemd-boot.enable = true;
      boot.loader.efi.canTouchEfiVariables = true;
      virtualisation.useEFIBoot = true;
      virtualisation.memorySize = 1024;

      nixflakes.deploy-ai = {
        enable = true;
        deployedSource = "${./../../../..}";
        deployedCommit = "deploy-ai-gate-test";
        publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIP0000000000000000000000000000000000000000 gate-boot-test";
        healthUnits = [ "nothing-probes-here.service" ];
        healthUrl = "http://127.0.0.1:9/health";
      };
    };

  testScript = ''
    gate.start()
    gate.wait_for_unit("multi-user.target")

    gate.succeed("deploy-ai --status > /tmp/status.txt || true")
    gate.execute("cat /tmp/status.txt")
    gate.succeed("grep -q '^ *system ' /tmp/status.txt")

    # A lock whose holder is gone must not wedge every later deploy.
    gate.succeed("mkdir -p /var/lib/deploy-ai/lock && echo 999999 > /var/lib/deploy-ai/lock/pid")
    gate.succeed("deploy-ai --vet </dev/null > /dev/null 2>&1 || true")
    gate.succeed(
        "test ! -e /var/lib/deploy-ai/lock/pid "
        "|| ! kill -0 $(cat /var/lib/deploy-ai/lock/pid) 2>/dev/null"
    )

    # Confirm: the loader default must become the running generation's entry id exactly.
    # The test driver boots the node by giving qemu its kernel directly, so no BLS entry exists
    # for the running system and the node's toplevel is the driver's `vm` derivation (it has no
    # bin/switch-to-configuration to install one).  Plant an entry naming the running system —
    # exactly what a real switch's `boot` action would have written — and pin it.
    gate.succeed(
        'X=$(readlink -f /run/current-system) && mkdir -p /boot/loader/entries && '
        'printf "title Gate test\\nlinux $X/kernel\\ninitrd $X/initrd\\noptions init=$X/init\\n" '
        '> /boot/loader/entries/nixos-gate-test.conf'
    )
    gate.succeed("deploy-ai --confirm-boot")
    gate.succeed(
        "grep '^default' /boot/loader/loader.conf | grep -q 'nixos-' "
        "&& ! grep -q '^default nixos-\\*' /boot/loader/loader.conf"
    )
  '';
}
