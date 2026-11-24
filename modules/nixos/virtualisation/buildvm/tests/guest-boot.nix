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
    guest.succeed(
        "test \"$(systemctl show bot-xvnc -p StartLimitIntervalUSec)\" = 'StartLimitIntervalUSec=0'"
    )
  '';
}
