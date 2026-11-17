{ config, lib, pkgs, ... }:
with lib;
let
  cfg = config.nixflakes.virtualisation.buildvm;
in
{
  options.nixflakes.virtualisation.buildvm = {
    enable = mkEnableOption "qemu/KVM build VM (the Hermes agent's execution host)";

    disk = mkOption {
      type = types.str;
      example = "/dev/disk/by-partlabel/buildvm";
      description = ''
        Raw block device passed straight through as the guest's only disk.  Created by hand
        (docs/buildvm-ai-setup.md section 3); the guest owns its partition table and filesystem, so
        the host never mounts it.
      '';
    };

    image = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = ''
        make-disk-image output directory, whose `*.img` is the bootable raw image (MBR partition
        table, GRUB inside the guest) written onto disk on first boot.  The image is a build-time
        path, not a runtime root: nothing in the host's store belongs to the guest.
      '';
    };

    publicKey = mkOption {
      type = types.str;
      default = "";
      description = "SSH public key the host uses to reach the guest, and that the gate accepts from it.";
    };

    privateKeyPath = mkOption {
      type = types.str;
      default = "/var/lib/buildvm/secrets/id_ed25519";
      description = "Private key on the host, mode 0600, root-owned.  Never in the repo.";
    };

    sshPort = mkOption {
      type = types.port;
      default = 2224;
      description = "Loopback port forwarded to the guest sshd (qemu user-mode networking).";
    };

    cpus = mkOption { type = types.ints.positive; default = 12; };

    memoryMiB = mkOption { type = types.ints.positive; default = 8192; };

    # The user defined in platforms/buildvm.nix; its ~/.ssh is what the install unit provisions.
    userName = mkOption { type = types.str; default = "builder"; };

    provisionDir = mkOption {
      type = types.str;
      default = "/var/lib/buildvm/secrets/guest-provision";
      description = ''
        Files copied into the guest filesystem while it is stopped (its ssh keys and known_hosts,
        which the guest needs to fetch the secrets input).  Nothing here enters the nix store.
      '';
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.image != null;
        message = "nixflakes.virtualisation.buildvm needs image";
      }
    ];

    environment.systemPackages = [ pkgs.qemu ];

    systemd.services.buildvm-install = {
      description = "Install the buildvm guest image onto its raw partition (first boot only)";
      # The guest grows its own filesystem (boot.growPartition), so this unit only ever writes the
      # image once and never resizes anything.
      wantedBy = [ "multi-user.target" ];
      before = [ "buildvm.service" ];
      serviceConfig.Type = "oneshot";
      serviceConfig.RemainAfterExit = true;
      path = [ pkgs.qemu pkgs.util-linux pkgs.coreutils ];
      script = ''
        DISK=${cfg.disk}
        IMAGE=${cfg.image}
        PROVISION=${cfg.provisionDir}

        if [ ! -b "$DISK" ]; then
          echo "buildvm: $DISK is not a block device - partition it per docs/buildvm-ai-setup.md section 3" >&2
          exit 1
        fi

        # make-disk-image yields a directory holding the raw file, not the file itself.
        IMAGE_FILE=$(ls "$IMAGE"/*.img 2>/dev/null | head -1 || true)
        if [ -z "$IMAGE_FILE" ]; then
          echo "buildvm: no *.img inside $IMAGE" >&2
          exit 1
        fi

        # Already installed (or made by hand) => leave the guest's data alone.  The image is
        # partitioned, so look for a partition table: a stale filesystem signature would otherwise
        # read as "installed", and an empty disk would read as "not installed".
        if [ -n "$(blkid -p -o value -s PTTYPE "$DISK" 2>/dev/null || true)" ]; then
          echo "buildvm: $DISK already partitioned, skipping install"
          exit 0
        fi

        echo "buildvm: writing $IMAGE_FILE to $DISK"
        qemu-img convert -f raw -O raw "$IMAGE_FILE" "$DISK"

        # Graft out-of-band guest files (the ssh keys it needs for the secrets input).  The VM is
        # stopped, so mounting its filesystem here is safe.  The uid goes in a plain variable: UID is
        # readonly in bash, so assigning it fails and chown would run with root's uid.
        if [ -d "$PROVISION" ] && [ -n "$(ls -A "$PROVISION" 2>/dev/null || true)" ]; then
          MNT=/mnt/buildvm
          mkdir -p "$MNT"
          # The image's root is the first partition *inside* it, so loop-mount with partitions.
          LOOP=$(losetup -f --show "$DISK")
          mount "$LOOP"p1 "$MNT"
          GUEST_UID=$(awk -F: '$1=="${cfg.userName}" {print $3}' "$MNT/etc/passwd" || true)
          if [ -n "$GUEST_UID" ]; then
            mkdir -p "$MNT/home/${cfg.userName}/.ssh"
            cp -r "$PROVISION"/. "$MNT/home/${cfg.userName}/.ssh/"
            chmod 700 "$MNT/home/${cfg.userName}/.ssh"
            find "$MNT/home/${cfg.userName}/.ssh" -type f -exec chmod 600 {} \;
            chown -R "$GUEST_UID:$GUEST_UID" "$MNT/home/${cfg.userName}/.ssh"
            echo "buildvm: provisioned guest ssh files for ${cfg.userName}"
          else
            echo "buildvm: user ${cfg.userName} not found in the guest, skipping provisioning" >&2
          fi
          umount "$MNT"
          losetup -d "$LOOP"
        fi
      '';
    };

    systemd.services.buildvm = {
      description = "buildvm - NixOS build VM for the Hermes agent (qemu/KVM)";
      after = [ "network-online.target" "buildvm-install.service" ];
      wants = [ "network-online.target" ];
      requires = [ "buildvm-install.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "simple";
        # Root: it owns the raw disk and needs /dev/kvm.
        User = "root";
        # The disk boots itself: GRUB lives in the guest image, so qemu gets no -kernel/-initrd/-append
        # and the kernel command line (console, root) comes from the guest's own bootloader config.
        # Keep notes outside ExecStart: systemd joins the backslash continuation lines into one
        # command line, so a # inside it would reach qemu as an argument.
        ExecStart = ''
          ${pkgs.qemu}/bin/qemu-system-x86_64 \
            -machine q35 -cpu host -enable-kvm \
            -smp ${toString cfg.cpus} -m ${toString cfg.memoryMiB} \
            -drive file=${cfg.disk},if=none,id=vd0,format=raw,cache=writeback \
            -device virtio-blk-pci,drive=vd0,bootindex=0 \
            -netdev user,id=n0,hostfwd=tcp:127.0.0.1:${toString cfg.sshPort}-:22 \
            -device virtio-net-pci,netdev=n0 \
            -nographic
        '';
        # qemu exits when the guest powers off; bring it back as a real host would.
        Restart = "always";
        RestartSec = "5s";
        TimeoutStopSec = "30s";
      };
    };
  };
}
