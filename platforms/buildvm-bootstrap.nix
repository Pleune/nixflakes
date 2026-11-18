# The seed image for the buildvm disk.
#
# Its only jobs are to make the raw partition bootable and to be reachable over ssh, so that the
# real guest system (platforms/buildvm.nix) can be built and switched to from inside the guest.
# Nothing else lives here, and that is the point:
#
# * Evaluated on its own - no ./modules/nixos, no ./config/nixos - so building it needs neither the
#   secrets input nor any host module, and it stays cheap enough to rebuild on a whim.
# * ai passes no kernel or initrd to qemu.  systemd-boot is written into the image's ESP, so the
#   host's store keeps no copy of the guest's system: `image` is a build-time path the garbage
#   collector reclaims once the partition has been written (docs/buildvm-ai-setup.md section 5).
#
# The image is small (a bare ext4 root sized to its own closure plus headroom) while the partition
# it lands on is 1.82 TiB, so boot.growPartition grows the root partition and filesystem on the
# guest's first boot; the host never resizes anything.
{ config, lib, pkgs, ... }:
let
  # No secrets input here by design, so no public key: buildvm-install grafts the keypair into the
  # guest before its first boot.
  buildvm = import ../lib/buildvm { };
in
{
  system.stateVersion = "25.05";
  networking.hostName = "buildvm";

  # ── Booting the disk itself ────────────────────────────────────────────────────────
  # make-disk-image runs switch-to-configuration boot inside a chroot of this system, which is what
  # installs systemd-boot onto the ESP it creates.  The kernel carries the EFI stub, so OVMF loads
  # vmlinuz directly; the loader is unsigned, hence ai runs plain pkgs.OVMF rather than OVMFFull.
  system.switch.enable = true;
  boot.loader.grub.enable = false;
  boot.loader.systemd-boot.enable = true;
  # Writes the boot entry into NVRAM.  That works when the guest runs under ai's OVMF with a
  # writable variable store; bootctl also installs the ESP fallback path, so a fresh store still
  # boots without any entry.
  boot.loader.efi.canTouchEfiVariables = true;
  # Each generation copies its kernel and initrd onto the ESP, so cap how many are kept.
  boot.loader.systemd-boot.configurationLimit = 4;

  boot.growPartition = true;

  # Serial console because qemu runs -nographic.  rd.shell=1 so a boot failure lands in a shell on
  # this console instead of a job that times out silently.
  boot.kernelParams = [ "console=ttyS0" "rd.shell=1" "panic=0" ];
  # Only what stage 1 needs to reach root; the ESP is mounted after switch root, where vfat can be
  # loaded from the store.
  boot.initrd.kernelModules = [ "virtio_pci" "virtio_blk" "ext4" ];

  # Matches the ext4 label make-disk-image puts on the image's root partition (the second one under
  # GPT).  Keep it equal to nixflakes.buildvm.diskImage's label below so a switched system mounts
  # the same root.
  fileSystems."/" = {
    device = "/dev/disk/by-label/buildvm";
    fsType = "ext4";
  };

  # make-disk-image formats the ESP with -n ESP, so label rather than index survives a re-partition.
  # noCheck: fsck.vfat is not in the initrd.
  fileSystems."/boot" = {
    device = "/dev/disk/by-label/ESP";
    fsType = "vfat";
    noCheck = true;
  };

  # ── Just enough to build and switch ────────────────────────────────────────────────
  nix.package = pkgs.nixVersions.latest;
  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  # The agent/human runs `nix nixos-rebuild switch --flake .#buildvm --accept-flake-config` as the
  # builder user, and trusting a flake's own config requires a trusted user.
  nix.settings.allowed-users = [ "*" ];
  nix.settings.trusted-users = [ "root" buildvm.userName ];

  services.openssh = {
    enable = true;
    settings.PasswordAuthentication = false;
    # Key-only root login: buildvm-install grafts the provisioning key into /root/.ssh here, and the
    # first switch (this seed -> .#buildvm) has to run as root because the builder user has no sudo.
    settings.PermitRootLogin = "prohibit-password";
  };

  # Same identity the full guest uses, so the host's ssh forward and the deploy key keep working
  # across the switch.
  users.users.${buildvm.userName} = {
    isNormalUser = true;
    shell = pkgs.bash;
    extraGroups = [ ];
    # The seed is reachable only with the key buildvm-install grafts into the guest before the
    # first boot, so it authorizes nothing itself.  (This system is evaluated without the secrets
    # input, so `buildvm.publicKey` is empty here by design.)
    openssh.authorizedKeys.keys = lib.optionals (buildvm.publicKey != "") [ buildvm.publicKey ];
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
