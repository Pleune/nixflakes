# The Hermes agent's execution host: a NixOS guest on ai, reachable over ssh.
# It is also the build machine for ai's own system, so its store holds most of the closure and
# ai's root filesystem stays small.
{ config, inputs, lib, pkgs, ... }:
with lib;
let
  buildvm = import ../lib/buildvm { private = inputs.private; };
in
{
  # Static address on qemu's NAT instead of DHCP; see that file for why.
  imports = [ ./buildvm-network.nix ];

  options = {
    nixflakes.buildvm.diskImage = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = ''
        Bootable raw disk image (GPT partition table + systemd-boot on its ESP) for the guest
        partition, for reseeding it by hand.  ai installs the seed image instead
        (platforms/buildvm-bootstrap.nix), and the guest grows its own root partition on boot, so
        nothing resizes this image on the host.
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

    # The guest boots its own disk: qemu gets no -kernel/-initrd/-append, so the loader has to live
    # in the image and `nixos-rebuild switch` inside the guest has to be able to reinstall it.
    system.switch.enable = true;
    # The kernel's EFI stub is what OVMF boots, and systemd-boot is the loader on the ESP.
    boot.loader.grub.enable = false;
    boot.loader.systemd-boot.enable = true;
    boot.loader.efi.canTouchEfiVariables = true;
    boot.loader.systemd-boot.configurationLimit = 4;

    # The image's root partition is a few GiB; the disk it lands on is 1.82 TiB.  The guest grows
    # the partition and the filesystem itself, on boot, before anything else mounts root.
    boot.growPartition = true;

    # Serial console because qemu runs -nographic; rd.shell=1 so a boot failure reaches this console
    # instead of timing out a device job in silence.
    boot.kernelParams = [ "console=ttyS0" "rd.shell=1" "panic=0" ];

    # The initrd must have virtio and ext4 before it can mount root.  The ESP is vfat but it is not
    # needed for boot, so systemd mounts /boot after switch root, where modprobe can load vfat from
    # the store.
    boot.initrd.kernelModules = [ "virtio_pci" "virtio_blk" "ext4" ];

    # Name root by the ext4 label make-disk-image writes (mkfs.ext4 -L buildvm) rather than
    # /dev/vda: systemd-fstab-generator writes sysroot.mount from the kernel root= line *before* it
    # reads the initrd fstab, so a second definition of the same node makes the generator fail with
    # "Failed to create unit file ... as it already exists" and the guest drops into Emergency Mode.
    fileSystems."/" = { device = "/dev/disk/by-label/buildvm"; fsType = "ext4"; };

    # The ESP systemd-boot lives on, labelled ESP by make-disk-image.
    fileSystems."/boot" = { device = "/dev/disk/by-label/ESP"; fsType = "vfat"; noCheck = true; };

    # Skip the repo's default user: no password login, no home-manager in a build VM.
    nixflakes.makeUser = false;

    users.users.${buildvm.userName} = {
      isNormalUser = true;
      shell = pkgs.bash;
      home = "/home/${buildvm.userName}";
      # In wheel for nix trust only: `config/nixos/core/nix` makes @wheel a nix trusted user, which the
      # in-guest flake switch needs.  There is deliberately no sudo here (see below), so this group
      # grants no privileges beyond nix.
      extraGroups = [ "wheel" ];
      openssh.authorizedKeys.keys = lib.optionals (buildvm.publicKey != "") [ buildvm.publicKey ];
    };

    services.openssh = {
      enable = true;
      settings = {
        PasswordAuthentication = false;
        # Key-only root login.  buildvm-install grafts the provisioning key into /root/.ssh, and the
        # switch that makes this guest what it is arrives as root over ssh
        # (modules/nixos/virtualisation/buildvm -> buildvm-provision.service).
        PermitRootLogin = "prohibit-password";
      };
    };

    # The guest user has no sudo at all: it has no password, and nixpkgs' wheel rule therefore makes
    # `sudo` fail rather than fall back to the password-less `%wheel` rule.  Anything that needs root
    # inside the guest comes in over ssh as root, which keeps one auditable path instead of a
    # passwordless root shell for whatever runs as the builder user.
    security.sudo.extraConfig = ''
      Defaults !lecture
    '';

    nixflakes.buildvm.diskImage = import "${inputs.nixpkgs}/nixos/lib/make-disk-image.nix" {
      inherit pkgs config lib;
      name = "buildvm-disk";
      label = "buildvm";
      format = "raw";
      # GPT with an ESP and an ext4 root, matching the loader config above; the root is the partition
      # boot.growPartition grows.
      partitionTableType = "efi";
      touchEFIVars = true;
      fsType = "ext4";
      # The partition is ~1.7 TiB; the image only needs the store plus headroom, and the guest
      # grows into the rest on its first boot.
      diskSize = "auto";
      additionalSpace = "4G";
      bootSize = "512M";
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
