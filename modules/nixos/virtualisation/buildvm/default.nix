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
      description = ''
        SSH public key the host uses to reach the guest, that the gate accepts from it, and that is
        written into the guest's ~/.ssh.  Empty means "write no key", which is what the seed image
        evaluates to.
      '';
    };

    privateKeyPath = mkOption {
      type = types.str;
      default = "/var/lib/buildvm/secrets/id_ed25519";
      description = ''
        Private half of the ai <-> buildvm keypair on the host, root-owned and readable by whatever
        units ssh to the guest.  platforms/ai.nix points this at the agenix path.
      '';
    };

    guestKeyPath = mkOption {
      type = types.str;
      default = cfg.privateKeyPath;
      description = ''
        Where the private half is written inside the guest, as builder's own ssh key, so the guest
        authenticates outbound with the identity the git host and ai already trust.
      '';
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

    # Repos handed to the guest from ai instead of from the git host.  Mirroring on ai means the
    # guest can be seeded, and switched, with no access to the git host at all; `origin` is still the
    # real URL so the agent can push once that host accepts the key it was given.
    repos = mkOption {
      type = types.listOf (types.submodule {
        options = {
          name = mkOption { type = types.str; description = "Label used in log lines."; };
          url = mkOption {
            type = types.str;
            description = "Upstream URL, fetched into the mirror and left as the clone's origin.";
          };
          mirror = mkOption {
            type = types.str;
            example = "/var/lib/buildvm/repos/nixflakes";
            description = "Bare mirror on ai, kept up to date on every install pass.";
          };
          home = mkOption {
            type = types.str;
            example = "nixflakes";
            description = "Directory to clone into, relative to the guest user's home.";
          };
        };
      });
      default = [ ];
      description = "Repos to mirror on ai and clone into the guest when it is seeded.";
    };

    provision = {
      enable = mkEnableOption "applying the guest's own NixOS config inside the guest, once per change";

      flakeAttr = mkOption {
        type = types.str;
        default = "buildvm";
        description = "nixosConfigurations attribute to build and switch to inside the guest.";
      };

      workdir = mkOption {
        type = types.str;
        default = "/home/${cfg.userName}/nixflakes";
        description = "The guest's nixflakes checkout to switch from.";
      };

      secretsDir = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          Guest checkout of the secrets repo, passed as `--override-input private` so the switch
          resolves the `private` input from disk instead of over ssh.
        '';
      };

      targetFile = mkOption {
        type = types.str;
        default = "/home/${cfg.userName}/deployed-commit";
        description = ''
          Guest file naming the commit to apply.  deploy-ai writes it after each successful ai
          deploy, so the guest ends up on the same tree the deploy was cut from.
        '';
      };

      markerFile = mkOption {
        type = types.str;
        default = "/home/${cfg.userName}/provisioned-commit";
        description = "Guest file recording what has already been applied, so a boot does not rebuild for nothing.";
      };
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
      # find is findutils, neither of which coreutils provides.  git is here for the mirrors.
      path = [ pkgs.qemu pkgs.git pkgs.util-linux pkgs.coreutils pkgs.systemd pkgs.gawk pkgs.findutils ];
      script = ''
        DISK=${cfg.disk}
        IMAGE=${cfg.image}
        VARS=${cfg.efiVarsPath}
        USER=${cfg.userName}
        PUBLIC_KEY=${escapeShellArg cfg.publicKey}
        KEY=${escapeShellArg cfg.guestKeyPath}
        MNT=/mnt/buildvm

        # Fetch a bare mirror on ai: clone when absent, fetch when present.  Failures are logged, not
        # fatal - a guest already seeded keeps working without the network.
        fetch_mirror() {
          mkdir -p "$(dirname "$1")"
          if [ -d "$1" ]; then
            git --git-dir="$1" fetch --quiet --prune origin '+refs/heads/*:refs/heads/*' \
              || echo "buildvm: mirror fetch of $1 failed" >&2
          else
            git clone --quiet --mirror "$2" "$1" \
              || echo "buildvm: mirror clone of $2 failed" >&2
          fi
        }

        # Clone a mirror into the guest's home, but only the first time: later passes never touch the
        # agent's own checkout.
        clone_home() {
          TARGET="$MNT/home/$USER/$2"
          [ -e "$TARGET/.git" ] && return 0
          mkdir -p "$(dirname "$TARGET")"
          git clone --quiet "$1" "$TARGET" \
            || { echo "buildvm: clone of $1 into $2 failed" >&2; return 0; }
          git -C "$TARGET" remote set-url origin "$3"
          chown -R "$GUEST_UID:$GUEST_UID" "$TARGET"
          echo "buildvm: cloned $2 into the guest from $1"
        }

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
        # read as "installed", and an empty disk would read as "not installed".  Grafting below
        # still runs, so a guest written before the keys existed gets them.
        if [ -n "$(blkid -p -o value -s PTTYPE "$DISK" 2>/dev/null || true)" ]; then
          echo "buildvm: $DISK already partitioned, skipping install"
        else
          echo "buildvm: writing $IMAGE_FILE to $DISK"
          qemu-img convert -f raw -O raw "$IMAGE_FILE" "$DISK"
        fi

        # Graft out-of-band guest files: the shared keypair and the repo checkouts.  This unit is
        # Before= the qemu unit, so the VM is stopped and mounting its filesystem here is safe.  The
        # uid goes in a plain variable: UID is readonly in bash, so assigning it fails and chown would
        # run with root's uid.
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
          # Grafting is out-of-band: the guest still boots without it, so keep the failure a
          # warning instead of blocking buildvm.service, which requires this unit.
          echo "buildvm: no partition labelled ${cfg.rootLabel} on $LOOP, skipping grafting" >&2
          losetup -d "$LOOP" || true
          exit 0
        fi

        mount "$ROOT" "$MNT"
        GUEST_UID=$(awk -F: '$1=="${cfg.userName}" {print $3}' "$MNT/etc/passwd" || true)
        if [ -z "$GUEST_UID" ]; then
          echo "buildvm: user ${cfg.userName} not found in the guest, skipping grafting" >&2
        else
          # builder's ~/.ssh, rewritten on every pass so a reseed is always correct.  The guest's
          # own ~/.ssh/authorized_keys is what sshd reads first, and nixpkgs puts the switch-time
          # authorized keys in /etc/ssh/authorized_keys.d instead, so this file survives a switch.
          SSH_DIR="$MNT/home/${cfg.userName}/.ssh"
          mkdir -p "$SSH_DIR"
          if [ -n "$PUBLIC_KEY" ]; then
            printf '%s\n' "$PUBLIC_KEY" > "$SSH_DIR/authorized_keys"
            printf '%s\n' "$PUBLIC_KEY" > "$SSH_DIR/id_ed25519.pub"
            chmod 600 "$SSH_DIR/authorized_keys" "$SSH_DIR/id_ed25519.pub"
          fi
          if [ -f "$KEY" ]; then
            cp "$KEY" "$SSH_DIR/id_ed25519"
            chmod 600 "$SSH_DIR/id_ed25519"
          else
            echo "buildvm: no private key at $KEY, guest gets no outbound key" >&2
          fi
          chmod 700 "$SSH_DIR"
          chown -R "$GUEST_UID:$GUEST_UID" "$SSH_DIR"
          echo "buildvm: grafted ssh keypair for ${cfg.userName}"

          # The mirrors are fetched with the same key: it is the deploy key the git host accepts.
          if [ -f "$KEY" ]; then
            export GIT_SSH_COMMAND="ssh -i $KEY -o BatchMode=yes -o StrictHostKeyChecking=accept-new"
          fi
          ${concatMapStringsSep "\n" (r: ''
          fetch_mirror ${escapeShellArg r.mirror} ${escapeShellArg r.url}
          clone_home ${escapeShellArg r.mirror} ${escapeShellArg r.home} ${escapeShellArg r.url} '') cfg.repos}
        fi

        sync
        umount "$MNT"
        losetup -d "$LOOP"
      '';
    };

    # Put the guest's own NixOS config onto the guest.  Until this runs, the machine behind
    # `ssh -p ${toString cfg.sshPort}` is the seed image (platforms/buildvm-bootstrap.nix): a
    # shell with git and sshd, no desktop, no gc, no sudo.  Everything it needs is on the disk
    # already - buildvm-install cloned the repos - so this is a reboot plus a switch, and it does
    # one pass per changed commit rather than a build on every boot.
    #
    # The commit to apply is the one deploy-ai recorded, i.e. the tree the running ai came from;
    # with no deploy recorded yet, the clone's own HEAD is used.
    systemd.services.buildvm-provision = mkIf cfg.provision.enable {
      description = "Apply the buildvm guest's own NixOS config inside the guest";
      wantedBy = [ "multi-user.target" ];
      after = [ "buildvm.service" ];
      requires = [ "buildvm.service" ];
      unitConfig.ConditionPathExists = cfg.privateKeyPath;
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        # A full guest system build (Xfce, Xvnc, nixVersions.latest) is slow; give it room.
        TimeoutStartSec = "45min";
      };
      path = [ pkgs.git pkgs.openssh pkgs.coreutils pkgs.findutils ];
      script = ''
        USER=${cfg.userName}
        PORT=${toString cfg.sshPort}
        KEY=${escapeShellArg cfg.privateKeyPath}
        WORK=${escapeShellArg cfg.provision.workdir}
        ATTR=${escapeShellArg cfg.provision.flakeAttr}
        TARGET_FILE=${escapeShellArg cfg.provision.targetFile}
        MARKER=${escapeShellArg cfg.provision.markerFile}
        OVERRIDE=${optionalString (cfg.provision.secretsDir != null) "--override-input private ${escapeShellArg cfg.provision.secretsDir}"}

        gssh() {
          ssh -i "$KEY" -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
            -p "$PORT" "$USER@127.0.0.1" "$@"
        }

        # The guest boots asynchronously; sshd takes a few seconds, and a reseed takes longer.
        READY=0
        for i in $(seq 1 180); do
          if gssh true; then READY=1; break; fi
          sleep 2
        done
        if [ "$READY" != 1 ]; then
          echo "buildvm-provision: guest ssh never came up on port $PORT" >&2
          exit 1
        fi

        TARGET=$(gssh "cat '$TARGET_FILE' 2>/dev/null || git -C '$WORK' rev-parse HEAD" | tr -d ' \n')
        if [ -z "$TARGET" ]; then
          echo "buildvm-provision: no commit to apply (missing $WORK?)" >&2
          exit 1
        fi
        if [ "$(gssh "cat '$MARKER' 2>/dev/null" | tr -d ' \n')" = "$TARGET" ]; then
          echo "buildvm-provision: guest already at $TARGET"
          exit 0
        fi
        if ! gssh "git -C '$WORK' cat-file -e '$TARGET^{commit}'"; then
          echo "buildvm-provision: $TARGET is not in the guest's checkout" >&2
          exit 1
        fi

        echo "buildvm-provision: switching the guest to $TARGET"
        if ! gssh "sudo nixos-rebuild switch --flake '$WORK#$ATTR' $OVERRIDE --accept-flake-config"; then
          echo "buildvm-provision: switch failed; guest left as it is" >&2
          exit 1
        fi

        # A switch changes the bootloader entries, so boot the new system rather than the one this
        # boot came from.  qemu restarts when the guest powers off (buildvm.service Restart=always).
        gssh "echo '$TARGET' > '$MARKER'"
        gssh "sudo reboot" || true
        BACK=0
        for i in $(seq 1 120); do
          sleep 3
          if gssh true; then BACK=1; break; fi
        done
        if [ "$BACK" != 1 ]; then
          echo "buildvm-provision: guest did not come back after the switch" >&2
          exit 1
        fi
        echo "buildvm-provision: guest running its own config at $TARGET"
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
