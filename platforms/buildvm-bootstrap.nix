# The seed image for the buildvm disk.
#
# Makes the raw partition bootable and reachable over ssh, so the real guest system
# (platforms/buildvm.nix) can be built and switched to from inside it.  Nothing else lives here:
#
# * Evaluated on its own - no ./modules/nixos, no ./config/nixos - so it needs neither the secrets
#   input nor a host module, and stays cheap to rebuild.
# * ai passes no kernel or initrd to qemu; systemd-boot lives in the image's ESP, so `image` is a
#   build-time path the GC reclaims once the partition is written.
#
# The image is small while its partition is 1.82 TiB; boot.growPartition widens the partition on boot
# and `autoResize` grows ext4 into it.  growpart alone leaves the filesystem at the image's size.
{ config, lib, pkgs, ... }:
let
  # No secrets input by design, and no public key: buildvm-install grafts the keypair before the first
  # boot, and this closure is streamed into the installer, so the seed image holds no key material.
  # Must match the name platforms/buildvm.nix and buildvm-install use.
  userName = "builder";
in
{
  # Same static addressing as the guest it is replaced by: provisioning sshes in on the forwarded port,
  # and the first switch fetches nixpkgs, which needs a route.
  imports = [ ./buildvm-network.nix ];

  system.stateVersion = "25.05";
  networking.hostName = "buildvm";

  # ── Booting the disk itself ────────────────────────────────────────────────────────
  # switch-to-configuration boot runs in make-disk-image's chroot, which installs systemd-boot on the
  # ESP it creates.  The kernel carries the EFI stub; the loader is unsigned, hence plain pkgs.OVMF.
  system.switch.enable = true;
  boot.loader.grub.enable = false;
  boot.loader.systemd-boot.enable = true;
  # Writes the boot entry into NVRAM, which ai's writable variable store allows; bootctl also installs
  # the ESP fallback path, so a fresh store boots without an entry.
  boot.loader.efi.canTouchEfiVariables = true;
  # Each generation copies its kernel and initrd onto the ESP, so cap how many are kept.
  boot.loader.systemd-boot.configurationLimit = 4;

  boot.growPartition = true;

  # Serial console because qemu runs -nographic; rd.shell=1 puts a boot failure in a shell instead of a
  # job that times out silently.
  boot.kernelParams = [ "console=ttyS0" "rd.shell=1" "panic=0" ];
  # Only what stage 1 needs to reach root; the ESP is mounted after switch root, where vfat can be
  # loaded from the store.
  boot.initrd.kernelModules = [ "virtio_pci" "virtio_blk" "ext4" ];

  # The ext4 label make-disk-image gives the root partition (the second one under GPT).  Keep it equal
  # to the diskImage label below so a switched system mounts the same root.
  fileSystems."/" = {
    device = "/dev/disk/by-label/buildvm";
    fsType = "ext4";
    # See platforms/buildvm.nix: the seed boots first, so it has to grow the filesystem too.
    autoResize = true;
  };

  # make-disk-image formats the ESP with -n ESP, so the label survives a re-partition.
  # noCheck: fsck.vfat is not in the initrd.
  fileSystems."/boot" = {
    device = "/dev/disk/by-label/ESP";
    fsType = "vfat";
    noCheck = true;
  };

  # ── Just enough to build and switch ────────────────────────────────────────────────
  nix.package = pkgs.nixVersions.latest;
  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  # The builder user runs `nixos-rebuild switch --flake .#buildvm --accept-flake-config`, and trusting a
  # flake's own config requires a trusted user.
  nix.settings.allowed-users = [ "*" ];
  nix.settings.trusted-users = [ "root" userName ];

  services.openssh = {
    enable = true;
    settings.PasswordAuthentication = false;
    # Key-only root login: buildvm-install grafts the provisioning key into /root/.ssh here, and the
    # first switch (this seed -> .#buildvm) has to run as root because the builder user has no sudo.
    settings.PermitRootLogin = "prohibit-password";
  };

  # Same identity the full guest uses, so the host's ssh forward and the deploy key keep working
  # across the switch.
  users.users.${userName} = {
    isNormalUser = true;
    shell = pkgs.bash;
    extraGroups = [ ];
    # The seed is reachable only with the key buildvm-install grafts into the guest before the first
    # boot, so it authorizes nothing itself.
    openssh.authorizedKeys.keys = [ ];
  };

  # Root has no password and no key here; without this NixOS refuses to evaluate, and the point of
  # the seed image is that its console stays usable when something fails to boot.
  users.allowNoPasswordLogin = true;

  environment.systemPackages = with pkgs; [
    git
    openssh
  ];

  # ── The image ai writes onto the partition ─────────────────────────────────────────
  # `efi` gives a GPT table with an ESP (partition 1, labelled ESP) and the ext4 root (partition 2),
  # which is what systemd-boot above installs onto and what boot.growPartition grows.  bootSize is
  # the offset the ESP ends at, so it bounds the ESP: 512 MiB holds the capped generation copies.
  # touchEFIVars lets the install chroot mount efivarfs, and emits efi-vars.fd next to the image.
  # diskSize "auto" sizes the image to the closure, so the seed stays small instead of carrying
  # 20 GiB of preallocated space.
  system.build.diskImage = import "${pkgs.path}/nixos/lib/make-disk-image.nix" {
    inherit config lib pkgs;
    name = "buildvm-bootstrap";
    label = "buildvm";
    format = "raw";
    partitionTableType = "efi";
    touchEFIVars = true;
    diskSize = "auto";
    additionalSpace = "2G";
    bootSize = "512M";
    copyChannel = false;
  };
}
