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
        Raw block device passed straight through as the guest's only disk.  Created by
        setup-buildvm-storage.sh; the guest owns its partition table and filesystem, so the host
        never mounts it.
      '';
    };

    image = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = "Raw guest image installed onto disk on first boot.";
    };

    kernel = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = "Guest kernel (bzImage), booted directly by qemu; the image carries no bootloader.";
    };

    initrd = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = "Guest initrd, booted directly by qemu.";
    };

    init = mkOption {
      type = types.str;
      default = "/init";
      description = "Path of the guest system's init, passed as init= on the kernel command line.";
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
        assertion = cfg.image != null && cfg.kernel != null && cfg.initrd != null;
        message = "nixflakes.virtualisation.buildvm needs image, kernel and initrd";
      }
    ];

    environment.systemPackages = [ pkgs.qemu pkgs.e2fsprogs ];

    systemd.services.buildvm-install = {
      description = "Install the buildvm guest image onto its raw partition (first boot only)";
      wantedBy = [ "multi-user.target" ];
      before = [ "buildvm.service" ];
      serviceConfig.Type = "oneshot";
      serviceConfig.RemainAfterExit = true;
      path = [ pkgs.qemu pkgs.e2fsprogs pkgs.util-linux pkgs.coreutils ];
      script = ''
        DISK=${cfg.disk}
        IMAGE=${cfg.image}
        PROVISION=${cfg.provisionDir}

        if [ ! -b "$DISK" ]; then
          echo "buildvm: $DISK is not a block device - run setup-buildvm-storage.sh on ai first" >&2
          exit 1
        fi

        # Already installed (or made by hand) => leave the guest's data alone.
        if [ -n "$(blkid -o value -s TYPE "$DISK" 2>/dev/null || true)" ]; then
          echo "buildvm: $DISK already holds a filesystem, skipping install"
          exit 0
        fi

        echo "buildvm: writing $IMAGE to $DISK"
        qemu-img convert -f raw -O raw "$IMAGE" "$DISK"

        # Grow the image's filesystem to the whole partition, offline while the guest is stopped.
        e2fsck -f -y "$DISK"
        resize2fs "$DISK"

        # Graft out-of-band guest files (the ssh keys it needs for the secrets input).  The VM is
        # stopped, so mounting its filesystem here is safe.
        if [ -d "$PROVISION" ] && [ -n "$(ls -A "$PROVISION" 2>/dev/null || true)" ]; then
          MNT=/mnt/buildvm
          mkdir -p "$MNT"
          mount "$DISK" "$MNT"
          UID=$(awk -F: '$1=="${cfg.userName}" {print $3}' "$MNT/etc/passwd" || true)
          if [ -n "$UID" ]; then
            mkdir -p "$MNT/home/${cfg.userName}/.ssh"
            cp -r "$PROVISION"/. "$MNT/home/${cfg.userName}/.ssh/"
            chmod 700 "$MNT/home/${cfg.userName}/.ssh"
            find "$MNT/home/${cfg.userName}/.ssh" -type f -exec chmod 600 {} \;
            chown -R "$UID:$UID" "$MNT/home/${cfg.userName}/.ssh"
            echo "buildvm: provisioned guest ssh files for ${cfg.userName}"
          else
            echo "buildvm: user ${cfg.userName} not found in the guest, skipping provisioning" >&2
          fi
          umount "$MNT"
        fi
      '';
    };

    systemd.services.buildvm = {
      description = "buildvm - NixOS build VM for the Hermes agent (qemu/KVM)";
      after = [ "network-online.target" "buildvm-install.service" ];
      requires = [ "buildvm-install.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "simple";
        # Root: it owns the raw disk and needs /dev/kvm.
        User = "root";
        ExecStart = ''
          ${pkgs.qemu}/bin/qemu-system-x86_64 \
            -machine q35 -cpu host -enable-kvm \
            -smp ${toString cfg.cpus} -m ${toString cfg.memoryMiB} \
            -kernel ${cfg.kernel} -initrd ${cfg.initrd} \
            -append "init=${cfg.init} root=/dev/vda rw console=ttyS0 rd.shell=0 panic=0" \
            -drive file=${cfg.disk},if=none,id=vd0,format=raw,cache=writeback \
            -device virtio-blk-pci,drive=vd0 \
            -netdev user,id=n0,hostfwd=tcp:127.0.0.1:${toString cfg.sshPort}-:22 \
            -device virtio-net-pci,netdev=n0 \
            -nographic
        '';
        # qemu exits when the guest powers off; bring it back as a real host would.
        Restart = "on-failure";
        RestartSec = "5s";
        TimeoutStopSec = "30s";
      };
    };
  };
}
