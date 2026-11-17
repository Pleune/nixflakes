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
        make-disk-image output directory, whose `*.img` is the bootable raw image (GPT partition
        table, systemd-boot on its ESP) written onto disk on first boot.  The image is a build-time
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

    # The guest boots UEFI, so qemu needs a firmware image plus somewhere to keep its variables.
    # Plain pkgs.OVMF, not OVMFFull: the latter compiles in Secure Boot (which would reject the
    # unsigned systemd-boot NixOS installs) and requires SMM, i.e. -machine q35,smm=on and a secure
    # pflash global, for features a local build VM has no use for.
    firmware = mkOption {
      type = types.path;
      default = pkgs.OVMF.firmware;
      defaultText = literalExpression "pkgs.OVMF.firmware";
      description = "Read-only EFI firmware (OVMF_CODE.fd).";
    };

    efiVariables = mkOption {
      type = types.path;
      default = pkgs.OVMF.variables;
      defaultText = literalExpression "pkgs.OVMF.variables";
      description = "EFI variable store template, copied to efiVarsPath when that file is missing.";
    };

    efiVarsPath = mkOption {
      type = types.str;
      default = "/var/lib/buildvm/efi-vars.fd";
      description = ''
        Writable OVMF variable store, so the boot entry the guest writes into NVRAM survives a
        reboot.  Deleting it resets the firmware to the template above.
      '';
    };

    rootLabel = mkOption {
      type = types.str;
      default = "buildvm";
      description = ''
        ext4 label of the guest's root partition, used to find it inside the image during
        provisioning.  Under GPT the root is the second partition, not the first.
      '';
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
      # Units get only this PATH, so every tool the script calls has to be listed: awk is gawk and
      # find is findutils, neither of which coreutils provides.
      path = [ pkgs.qemu pkgs.util-linux pkgs.coreutils pkgs.systemd pkgs.gawk pkgs.findutils ];
      script = ''
        DISK=${cfg.disk}
        IMAGE=${cfg.image}
        PROVISION=${cfg.provisionDir}
        VARS=${cfg.efiVarsPath}

        if [ ! -b "$DISK" ]; then
          echo "buildvm: $DISK is not a block device - partition it per docs/buildvm-ai-setup.md section 3" >&2
          exit 1
        fi

        # qemu's pflash unit must point at an existing file of the firmware's own size, so seed it
        # from the template.  Kept once, never overwritten: it holds the guest's NVRAM.
        if [ ! -f "$VARS" ]; then
          mkdir -p "$(dirname "$VARS")"
          install -m 0644 ${cfg.efiVariables} "$VARS"
          echo "buildvm: seeded EFI variable store $VARS"
        fi

        # make-disk-image yields a directory holding the raw file, not the file itself.
        IMAGE_FILE=$(ls "$IMAGE"/*.img 2>/dev/null | head -1 || true)
        if [ -z "$IMAGE_FILE" ]; then
          echo "buildvm: no *.img inside $IMAGE" >&2
          exit 1
        fi

        # Already installed (or made by hand) => leave the guest's data alone.  The image is
        # partitioned, so look for a partition table: a stale filesystem signature would otherwise
        # read as "installed", and an empty disk would read as "not installed".  Provisioning below
        # still runs, so a guest written before the keys existed gets them.
        if [ -n "$(blkid -p -o value -s PTTYPE "$DISK" 2>/dev/null || true)" ]; then
          echo "buildvm: $DISK already partitioned, skipping install"
        else
          echo "buildvm: writing $IMAGE_FILE to $DISK"
          qemu-img convert -f raw -O raw "$IMAGE_FILE" "$DISK"
        fi

        # Graft out-of-band guest files (the ssh keys it needs for the secrets input).  This unit is
        # Before= the qemu unit, so the VM is stopped and mounting its filesystem here is safe.  The
        # uid goes in a plain variable: UID is readonly in bash, so assigning it fails and chown would
        # run with root's uid.
        if [ -d "$PROVISION" ] && [ -n "$(ls -A "$PROVISION" 2>/dev/null || true)" ]; then
          MNT=/mnt/buildvm
          mkdir -p "$MNT"
          # The image's partitions live *inside* it, so the loop device has to scan its partition
          # table (-P); without it no /dev/loop0p1 node is ever created and mount fails with
          # "Can't lookup blockdev".
          LOOP=$(losetup -f --show -P "$DISK")
          udevadm settle --timeout=10 || true
          # GPT puts the ESP first, so the root is whichever partition carries the image's label
          # rather than a fixed index; a hand-made single-partition disk matches the same label.
          ROOT=""
          for part in "$LOOP"p*; do
            if [ "$(blkid -p -o value -s LABEL "$part" 2>/dev/null || true)" = "${cfg.rootLabel}" ]; then
              ROOT="$part"
              break
            fi
          done
          if [ -z "$ROOT" ]; then
            # Provisioning is out-of-band: the guest still boots without it, so keep the failure a
            # warning instead of blocking buildvm.service, which requires this unit.
            echo "buildvm: no partition labelled ${cfg.rootLabel} on $LOOP, skipping provisioning" >&2
            losetup -d "$LOOP" || true
          else
            mount "$ROOT" "$MNT"
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
        # The disk boots itself: systemd-boot lives on the guest's ESP and the kernel carries the EFI
        # stub, so qemu gets no -kernel/-initrd/-append and the kernel command line comes from the
        # guest's own loader entries.  unit=0 is the read-only firmware, unit=1 the writable variable
        # store buildvm-install seeds.
        # Keep notes outside ExecStart: systemd joins the backslash continuation lines into one
        # command line, so a # inside it would reach qemu as an argument.
        ExecStart = ''
          ${pkgs.qemu}/bin/qemu-system-x86_64 \
            -machine q35 -cpu host -enable-kvm \
            -smp ${toString cfg.cpus} -m ${toString cfg.memoryMiB} \
            -drive if=pflash,format=raw,unit=0,readonly=on,file=${cfg.firmware} \
            -drive if=pflash,format=raw,unit=1,file=${cfg.efiVarsPath} \
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
