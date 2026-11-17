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
        Bootable raw disk image (MBR partition table + GRUB) for the guest partition, for reseeding
        it by hand.  ai installs the seed image instead (platforms/buildvm-bootstrap.nix), and the
        guest grows its own root partition on boot, so nothing resizes this image on the host.
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

    # The guest boots its own disk: qemu gets no -kernel/-initrd/-append, so GRUB has to live in the
    # partition and `nixos-rebuild switch` inside the guest has to be able to reinstall it.
    system.switch.enable = true;
    boot.loader.grub.enable = true;
    boot.loader.grub.efiSupport = false;
    # The only virtio disk, which is also the device the image was installed onto.
    boot.loader.grub.device = "/dev/vda";
    boot.loader.efi.canTouchEfiVariables = false;

    # The image's root partition is a few GiB; the disk it lands on is 1.82 TiB.  The guest grows
    # the partition and the filesystem itself, on boot, before anything else mounts root.
    boot.growPartition = true;

    # Serial console because qemu runs -nographic; rd.shell=1 so a boot failure reaches this console
    # instead of timing out a device job in silence.
    boot.kernelParams = [ "console=ttyS0" "rd.shell=1" "panic=0" ];

    # The initrd must have virtio and ext4 before it can mount root.
    boot.initrd.kernelModules = [ "virtio_pci" "virtio_blk" "ext4" ];

    # Name root by the ext4 label make-disk-image writes (mkfs.ext4 -L buildvm) rather than
    # /dev/vda: systemd-fstab-generator writes sysroot.mount from the kernel root= line *before* it
    # reads the initrd fstab, so a second definition of the same node makes the generator fail with
    # "Failed to create unit file ... as it already exists" and the guest drops into Emergency Mode.
    fileSystems."/" = { device = "/dev/disk/by-label/buildvm"; fsType = "ext4"; };

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
      # MBR table with one ext4 partition, which is what boot.loader.grub above installs onto and
      # what boot.growPartition grows.
      partitionTableType = "legacy";
      fsType = "ext4";
      # The partition is ~1.7 TiB; the image only needs the store plus headroom, and the guest
      # grows into the rest on its first boot.
      diskSize = "auto";
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
