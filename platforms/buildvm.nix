# The Hermes agent's execution host: a NixOS guest on ai, reachable over ssh.
# It is also the build machine for ai's own system, so its store holds most of the closure and
# ai's root filesystem stays small.
{ config, inputs, lib, pkgs, ... }:
with lib;
let
  buildvm = import ../lib/buildvm;
in
{
  options = {
    nixflakes.buildvm.diskImage = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = ''
        Raw ext4 filesystem image (no partition table) that seeds the guest partition on ai.
        Installed once by the buildvm-install unit, then grown to fill the partition; the guest
        owns everything inside it, including its own partition table-free layout.
      '';
    };

    nixflakes.buildvm.desktop = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Install Xvnc + Xfce + a browser.  bot_desktop runs inside this guest
        (services.hermes-agent.settings.bot_desktop.placement = "auto" on ai) and Hermes cannot
        install anything on NixOS: it only checks for these binaries, and its package map covers
        apt/dnf/pacman only (hermes tools/bot_desktop/runtime.py REQUIRED_BINARIES).
      '';
    };
  };

  config = {
    nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";

    networking.hostName = "buildvm";

    # No physical install: qemu boots this config with -kernel/-initrd/-append, so there is
    # nothing for a bootloader to do and switch-to-configuration must not look for one.
    boot.loader.grub.enable = false;
    boot.loader.efi.canTouchEfiVariables = false;

    # The image is a bare ext4 filesystem written onto the host partition (/dev/vda in the guest),
    # so stage 1 needs virtio and ext4 before it can mount root.
    boot.initrd.kernelModules = [ "virtio_pci" "virtio_blk" "ext4" ];

    # The raw image is a bare ext4 filesystem on the whole virtio disk, and qemu passes
    # root=/dev/vda, so there is no partition to name here.
    fileSystems."/" = { device = "/dev/vda"; fsType = "ext4"; };

    # Skip the repo's default user: no password login, no home-manager in a build VM.
    nixflakes.makeUser = false;

    users.users.${buildvm.userName} = {
      isNormalUser = true;
      shell = pkgs.bash;
      home = "/home/${buildvm.userName}";
      # Not in wheel: the agent builds and pushes; it activates nothing on ai.
      extraGroups = [ ];
      openssh.authorizedKeys.keys = [ buildvm.publicKey ];
    };

    services.openssh = {
      enable = true;
      settings = {
        PasswordAuthentication = false;
        PermitRootLogin = "no";
      };
    };

    nixflakes.buildvm.diskImage = import "${inputs.nixpkgs}/nixos/lib/make-disk-image.nix" {
      inherit pkgs config lib;
      name = "buildvm-disk";
      label = "buildvm";
      format = "raw";
      partitionTableType = "none";
      installBootLoader = false;
      fsType = "ext4";
      # The partition is ~1.7 TiB; the image only needs to hold the store plus headroom, and
      # buildvm-install resize2fs's it to the whole partition on first boot.
      diskSize = 20480;
      additionalSpace = "4G";
    };

    environment.systemPackages = with pkgs; [
      git
      openssh
      nixVersions.latest
      deploy-rs
      jq
    ] ++ optionals config.nixflakes.buildvm.desktop (with pkgs; [
      tigervnc # Xvnc
      xfwm4
      xfce4-panel
      xfdesktop
      xfce4-settings # xfsettingsd
      xfce4-terminal
      dbus # dbus-run-session
      xauth
      xdpyinfo
      setxkbmap
      xprop
      chromium
      dejavu_fonts
    ]);

    nix.gc = {
      automatic = true;
      dates = "daily";
      options = "--delete-older-than 14d";
    };

    # Keep build logs from filling the guest disk.
    services.journald.settings.Journal = {
      SystemMaxUse = "512M";
      RuntimeMaxUse = "128M";
    };

    systemd.services.nix-daemon.serviceConfig.LimitNOFILE = 65536;

    system.stateVersion = "25.05";
  };
}
