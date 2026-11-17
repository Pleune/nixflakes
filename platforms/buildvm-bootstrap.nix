# The seed image for the buildvm disk.
#
# Its only jobs are to make the raw partition bootable and to be reachable over ssh, so that the
# real guest system (platforms/buildvm.nix) can be built and switched to from inside the guest.
# Nothing else lives here, and that is the point:
#
# * Evaluated on its own - no ./modules/nixos, no ./config/nixos - so building it needs neither the
#   secrets input nor any host module, and it stays cheap enough to rebuild on a whim.
# * ai passes no kernel or initrd to qemu.  GRUB is written into the image, so the host's store
#   keeps no copy of the guest's system: `image` is a build-time path the garbage collector reclaims
#   once the partition has been written (docs/buildvm-ai-setup.md section 5).
#
# The image is small (a bare ext4 root sized to its own closure plus headroom) while the partition
# it lands on is 1.82 TiB, so boot.growPartition grows the root partition and filesystem on the
# guest's first boot; the host never resizes anything.
{ config, lib, pkgs, ... }:
let
  buildvm = import ../lib/buildvm;
in
{
  system.stateVersion = "25.05";
  networking.hostName = "buildvm";

  # ── Booting the disk itself ────────────────────────────────────────────────────────
  # make-disk-image runs switch-to-configuration boot inside a chroot of this system, which is what
  # writes GRUB into the MBR partition table it creates.
  system.switch.enable = true;
  boot.loader.grub.enable = true;
  boot.loader.grub.efiSupport = false;
  # qemu names the only disk vda; make-disk-image symlinks this device to the disk it installs onto.
  boot.loader.grub.device = "/dev/vda";

  boot.growPartition = true;

  # Serial console because qemu runs -nographic.  rd.shell=1 so a boot failure lands in a shell on
  # this console instead of a job that times out silently.
  boot.kernelParams = [ "console=ttyS0" "rd.shell=1" "panic=0" ];
  boot.initrd.kernelModules = [ "virtio_pci" "virtio_blk" "ext4" ];

  # Matches the ext4 label make-disk-image puts on the image's first partition.  Keep it equal to
  # nixflakes.buildvm.diskImage's label below so a switched system mounts the same root.
  fileSystems."/" = {
    device = "/dev/disk/by-label/buildvm";
    fsType = "ext4";
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
    settings.PermitRootLogin = "no";
  };

  # Same identity the full guest uses, so the host's ssh forward and the deploy key keep working
  # across the switch.
  users.users.${buildvm.userName} = {
    isNormalUser = true;
    shell = pkgs.bash;
    extraGroups = [ ];
    openssh.authorizedKeys.keys = [ buildvm.publicKey ];
  };

  # Root has no password and no key here; without this NixOS refuses to evaluate, and the point of
  # the seed image is that its console stays usable when something fails to boot.
  users.allowNoPasswordLogin = true;

  environment.systemPackages = with pkgs; [
    git
    openssh
  ];

  # ── The image ai writes onto the partition ─────────────────────────────────────────
  # `legacy` gives an MBR table with one ext4 partition, which is what GRUB above installs onto and
  # what boot.growPartition grows.  diskSize "auto" sizes the image to the closure, so the seed
  # stays small instead of carrying 20 GiB of preallocated space.
  system.build.diskImage = import "${pkgs.path}/nixos/lib/make-disk-image.nix" {
    inherit config lib pkgs;
    name = "buildvm-bootstrap";
    label = "buildvm";
    format = "raw";
    partitionTableType = "legacy";
    diskSize = "auto";
    additionalSpace = "2G";
    bootSize = "128M";
    copyChannel = false;
  };
}
