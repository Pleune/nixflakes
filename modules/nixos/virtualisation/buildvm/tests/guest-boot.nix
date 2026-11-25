{ inputs }:

# The build VM's own platform config, booted as a real machine.  This is the check that would
# have caught, before any deploy, everything the field taught us the hard way: builder must
# linger (a dead user manager made switch-to-configuration exit 4 and provisioning bail), the
# agent-browser units must come up and Chromium must answer CDP on 9222, the browser units must
# escape the start limit (`Restart=always` + a start-limit-hit no one resets), and the memory
# guardrails must be present — zram + max-jobs is the OOM fix that silently fell out of main once.
#
# The test driver's disk labels its root partition `nixos`, not `buildvm`, so the fstab device
# is overridden here; the ESP label `ESP` matches the driver's image as-is.
#
# `runNixOSTest` is the module-style entry point: `node.specialArgs` is a real test option here,
# which is how the platform config gets the same module arguments flake.nix's `specialArgs` gives
# it (makeTest's legacy arg list rejects that option outright).
let
  sysdef = {
    username = "mitch";
    userFullName = "Mitchell Pleune";
    userEmail = "mitchpleune@gmail.com";
  };
in
{ pkgs, ... }:
{
  name = "buildvm-guest-boot";

  node.specialArgs = {
    inherit inputs sysdef;
    self = inputs.self;
    inputs' = inputs;
    self' = inputs.self;
    hostName = "buildvm";
    packages = { };
    root = ../../../../../.;
  } // sysdef // inputs;

  # The platform config legitimately sets `nixpkgs.*` (hostPlatform, overlays, config); the
  # tester's read-only guard would reject that, so the guest evaluates with it off.
  node.pkgsReadOnly = false;

  nodes.guest =
    { pkgs, ... }:
    {
      imports = [
        ../../../../../modules/nixos
        ../../../../../config/nixos
        ../../../../../platforms/buildvm.nix
      ];

      virtualisation.useEFIBoot = true;
      virtualisation.memorySize = 3072;

      fileSystems."/".device = "/dev/disk/by-label/nixos";

      environment.systemPackages = [ pkgs.curl ];
    };

  testScript = ''
    guest.start()
    guest.wait_for_unit("multi-user.target")

    guest.wait_for_unit("bot-xvnc.service")
    guest.wait_for_unit("chromium-cdp.service")
    guest.wait_for_open_port(9222)
    guest.succeed("curl -sf http://127.0.0.1:9222/json/version | grep -q Browser")

    guest.succeed("test -b /dev/zram0")
    guest.succeed("grep -q '^max-jobs = 2' /etc/nix/nix.conf")
    guest.succeed("grep -q '^cores = 2' /etc/nix/nix.conf")
    guest.succeed("test -f /var/lib/systemd/linger/builder")
    # computer_use spawns `cua-driver` from the guest's PATH.  `--version` exercises the
    # binary's dynamic loader (X11/PipeWire/libxkbcommon deps), so a missing package or a
    # broken link both fail here.
    guest.succeed("cua-driver --version")
    # /tmp survives reboots here, so boot must wipe it wholesale (boot.tmp.cleanOnBoot ->
    # `D! /tmp`).  A stale bot-desktop screen env (a published DISPLAY whose Xvnc died) would
    # otherwise make Hermes adopt the dead display and computer_use spawn its driver against
    # nothing; the wipe also covers arbitrary scratch files.  The `!` means the rule only runs
    # with --boot, which is exactly how systemd-tmpfiles-setup.service invokes tmpfiles at boot,
    # and tmpfiles never removes files younger than ~10s, so the planted files are backdated.
    guest.succeed(
        "mkdir -p /tmp/hermes-bot-desktop/default && echo 'DISPLAY=:20' > /tmp/hermes-bot-desktop/default/env"
    )
    guest.succeed("mkdir -p /tmp/stale-dir && touch /tmp/stale-file /tmp/stale-dir/nested")
    guest.succeed("find /tmp/hermes-bot-desktop /tmp/stale-dir /tmp/stale-file -exec touch -d '1 hour ago' {} +")
    guest.succeed("systemd-tmpfiles --create --remove --boot --exclude-prefix=/dev")
    guest.succeed("! test -e /tmp/hermes-bot-desktop/default/env")
    guest.succeed("! test -e /tmp/stale-file")
    guest.succeed("! test -e /tmp/stale-dir")
    guest.succeed("test -d /tmp")
    guest.succeed(
        "test \"$(systemctl show bot-xvnc -p StartLimitIntervalUSec)\" = 'StartLimitIntervalUSec=0'"
    )
  '';
}
