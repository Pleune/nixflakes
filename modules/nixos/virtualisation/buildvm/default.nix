{ config, lib, pkgs, ... }:
with lib;
let
  cfg = config.nixflakes.virtualisation.buildvm;
  # Provisioning always gets a key of its own when it is enabled; loginKeys adds the other consumers
  # (Hermes, tooling).
  loginKeyList =
    lib.optionals cfg.provision.enable [
      { name = "provision"; path = cfg.provision.loginKey; owner = "root"; group = "root"; }
    ]
    ++ attrValues cfg.loginKeys;
  # The guest's ordinary user has no sudo, so activation can only run as root: keys the host runs as
  # root are the ones authorized in the guest's /root/.ssh/authorized_keys.
  rootKeyList = filter (k: k.owner == "root") loginKeyList;
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
        Public half of the keypair the guest authenticates *outbound* with (the git host's deploy key),
        written into the guest's ~/.ssh and left in its authorized_keys so root units on ai can also
        log in with it.  Empty means "write no key".
      '';
    };

    privateKeyPath = mkOption {
      type = types.str;
      default = "/var/lib/buildvm/secrets/id_ed25519";
      description = ''
        Private half of the guest's outbound keypair, decrypted by agenix and grafted into the guest as
        the build user's own ssh identity.  Only root reads it on the host, so it can stay 0600.
      '';
    };

    loginKeysDir = mkOption {
      type = types.str;
      default = "/var/lib/buildvm/keys";
      description = ''
        Where buildvm-install generates the host-side keypairs that log *into* the guest, one directory
        per consumer.
      '';
    };

    # ssh refuses to use a private key whose permissions let anyone other than its owner read it: on
    # ai the hermes units reported `Permissions 0640 for '/run/agenix/ai_buildvm_id_ed25519' are too
    # open` / `This private key will be ignored` for a root:hermes 0640 file.  A shared, group-readable
    # key is therefore unusable, so each consumer gets its own generated pair.
    loginKeys = mkOption {
      type = types.attrsOf (types.submodule ({ name, ... }: {
        options = {
          name = mkOption {
            type = types.str;
            default = name;
            description = "Comment stamped into the generated key, and the directory name under loginKeysDir.";
          };
          path = mkOption {
            type = types.str;
            default = "${cfg.loginKeysDir}/${name}/id_ed25519";
            example = "/var/lib/buildvm/keys/hermes/id_ed25519";
            description = "Private key file, created by buildvm-install when it is missing.";
          };
          owner = mkOption {
            type = types.str;
            default = "root";
            description = ''
              User that runs ssh with this key, and therefore owns the file.  Must exist on the host.
            '';
          };
          group = mkOption {
            type = types.str;
            default = "root";
            description = "Group of the key file and of its directory.";
          };
        };
      }));
      default = { };
      description = ''
        Host keypairs buildvm-install generates on first run and authorizes in the guest.  Give one per
        user that sshes into the guest (Hermes, ad-hoc tooling); provisioning has its own option.
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
          Where the secrets tree lands in the guest, passed as `--override-input private` so the
          switch resolves the `private` input from disk instead of over ssh.  It is a copy of the
          whole `private` input, flake.nix included, so that override is a valid flake.
        '';
      };

      secretsSource = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = ''
          Path on ai whose contents are streamed into secretsDir by buildvm-provision, normally the
          `private` input ai itself evaluated against.  A plain copy, not a git checkout: the guest
          reads the same secrets ai used and needs no deploy key for the secrets repo.
        '';
      };

      sourcePath = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "/nix/store/...-source";
        description = ''
          Directory on ai holding the nixflakes tree ai was built from, streamed into the guest's
          workdir by buildvm-provision.  Provisioning rather than seeding because the guest must
          switch to the tree this machine is running, which only exists once ai has been deployed.
        '';
      };

      origin = mkOption {
        type = types.str;
        default = "";
        description = ''
          Remote the guest's checkout is pointed at, so the agent inside the VM can push.  History is
          fetched from it; with no access the streamed tree is still a working flake, it just has no
          commits behind it.
        '';
      };

      targetCommit = mkOption {
        type = types.str;
        default = "";
        description = ''
          Commit the guest should be on, normally `self.rev` of the source ai was deployed from.  Empty
          means fall back to the file deploy-ai records in the guest.
        '';
      };

      loginKey = mkOption {
        type = types.str;
        default = "${cfg.loginKeysDir}/provision/id_ed25519";
        description = ''
          Root-owned keypair provisioning logs into the guest with, generated by buildvm-install.  It is
          deliberately not the guest's outbound key: ssh needs a key the invoking user owns, and that
          key is grafted into the guest.
        '';
      };

      activationUser = mkOption {
        type = types.str;
        default = "root";
        description = ''
          Guest user that runs the activation (the switch and the reboot).  The ordinary guest user has
          no sudo, so this must be a user buildvm-install authorized with a root-owned login key.
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

      knownHostsFile = mkOption {
        type = types.str;
        default = "/var/lib/buildvm/guest-known_hosts";
        description = ''
          Root-owned known_hosts holding the guest's sshd host key, used only by the provisioning
          ssh.  buildvm-install deletes it when it writes a fresh image, so a reseed re-trusts the
          guest's new key instead of failing on a changed fingerprint.
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
      # agenix decrypts the keypair through activation scripts, and the copy of those scripts that
      # runs at boot is nixos-activation.service, so order after it.  Without this the unit starts
      # while /run/agenix is still empty and the guest gets no private key.
      after = [ "nixos-activation.service" ];
      serviceConfig.Type = "oneshot";
      serviceConfig.RemainAfterExit = true;
      # Units get only this PATH, so every tool the script calls has to be listed: awk is gawk and
      # find is findutils, neither of which coreutils provides, and git needs openssh for its ssh
      # transport ("error: cannot run ssh" otherwise).
      path = [ pkgs.qemu pkgs.git pkgs.openssh pkgs.util-linux pkgs.coreutils pkgs.systemd pkgs.gawk pkgs.findutils ];
      script = ''
        DISK=${cfg.disk}
        IMAGE=${cfg.image}
        VARS=${cfg.efiVarsPath}
        USER=${cfg.userName}
        PUBLIC_KEY=${escapeShellArg cfg.publicKey}
        KEY=${escapeShellArg cfg.guestKeyPath}
        MNT=/mnt/buildvm

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

        # Graft out-of-band guest files: the keys.  Repos and secrets are placed by buildvm-provision,
        # which runs once ai has been deployed and therefore knows which nixflakes tree this machine is
        # running.  This unit is Before= the qemu unit, so the VM is stopped and mounting its filesystem
        # here is safe.  The uid goes in a plain variable: UID is readonly in bash, so assigning it
        # fails and chown would run with root's uid.
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

        # A host keypair that logs *into* the guest.  Generated here rather than kept in the secrets
        # repo: ssh only accepts a key its invoking user owns, so every consumer needs its own file,
        # and these have no reason to be secret on a machine that generates them anyway.
        gen_login_key() {
          # $1 private key path, $2 owner, $3 group, $4 name
          local KEY_DIR
          KEY_DIR=$(dirname "$1")
          mkdir -p "$KEY_DIR"
          if [ ! -f "$1" ]; then
            ssh-keygen -q -t ed25519 -N "" -C "buildvm-login:$4" -f "$1" || { echo "buildvm: cannot generate $1" >&2; return 0; }
          elif [ ! -f "$1.pub" ]; then
            # A key kept but its pub lost would leave the guest authorizing nothing, so re-derive it.
            ssh-keygen -y -f "$1" > "$1.pub" || { echo "buildvm: cannot derive $1.pub" >&2; return 0; }
          fi
          chown "$2:$3" "$KEY_DIR" "$1" "$1.pub"
          chmod 700 "$KEY_DIR"
          chmod 600 "$1"
          chmod 644 "$1.pub"
        }

        mount "$ROOT" "$MNT"
        GUEST_UID=$(awk -F: '$1=="${cfg.userName}" {print $3}' "$MNT/etc/passwd" || true)
        if [ -z "$GUEST_UID" ]; then
          echo "buildvm: user ${cfg.userName} not found in the guest, skipping grafting" >&2
        else
          ${concatMapStringsSep "\n" (k: ''
          gen_login_key ${escapeShellArg k.path} ${escapeShellArg k.owner} ${escapeShellArg k.group} ${escapeShellArg k.name}'') loginKeyList}

          # builder's ~/.ssh, rewritten on every pass so a reseed is always correct.  The guest's
          # own ~/.ssh/authorized_keys is what sshd reads first, and nixpkgs puts the switch-time
          # authorized keys in /etc/ssh/authorized_keys.d instead, so this file survives a switch.
          SSH_DIR="$MNT/home/${cfg.userName}/.ssh"
          mkdir -p "$SSH_DIR"
          # Who may log into the guest: the generated login keys, plus the outbound key's public half
          # so root units on ai (deploy-ai) can still use the keypair they already hold.
          : > "$SSH_DIR/authorized_keys"
          ${lib.optionalString (loginKeyList != [ ]) ''
          for PUB in ${escapeShellArgs (map (k: "${k.path}.pub") loginKeyList)}; do
            if [ -f "$PUB" ]; then cat "$PUB" >> "$SSH_DIR/authorized_keys"; fi
          done
          ''}
          if [ -n "$PUBLIC_KEY" ]; then
            printf '%s\n' "$PUBLIC_KEY" >> "$SSH_DIR/authorized_keys"
            printf '%s\n' "$PUBLIC_KEY" > "$SSH_DIR/id_ed25519.pub"
          fi
          chmod 600 "$SSH_DIR/authorized_keys"
          [ -f "$SSH_DIR/id_ed25519.pub" ] && chmod 600 "$SSH_DIR/id_ed25519.pub"
          if [ -f "$KEY" ]; then
            cp "$KEY" "$SSH_DIR/id_ed25519"
            chmod 600 "$SSH_DIR/id_ed25519"
          else
            echo "buildvm: no private key at $KEY, guest gets no outbound key" >&2
          fi
          chmod 700 "$SSH_DIR"
          chown -R "$GUEST_UID:$GUEST_UID" "$SSH_DIR"
          echo "buildvm: grafted ssh keypair for ${cfg.userName}"

          # Root inside the guest, authorized with the keys the host runs as root.  The guest's user
          # has no sudo, so the provisioning switch and the reboot have to arrive as root.
          ROOT_DIR="$MNT/root/.ssh"
          mkdir -p "$ROOT_DIR"
          : > "$ROOT_DIR/authorized_keys"
          ${lib.optionalString (rootKeyList != [ ]) ''
          for PUB in ${escapeShellArgs (map (k: "${k.path}.pub") rootKeyList)}; do
            if [ -f "$PUB" ]; then cat "$PUB" >> "$ROOT_DIR/authorized_keys"; fi
          done
          ''}
          if [ -n "$PUBLIC_KEY" ]; then
            printf '%s\n' "$PUBLIC_KEY" >> "$ROOT_DIR/authorized_keys"
          fi
          chmod 700 "$ROOT_DIR"
          chmod 600 "$ROOT_DIR/authorized_keys"
          chown -R 0:0 "$ROOT_DIR"
          echo "buildvm: authorized root in the guest"

          # Every graft pass rewrites the guest's keys, and a fresh image brings fresh sshd host
          # keys, so whatever was pinned before this pass is suspect.  Drop it here rather than only
          # on a reseed: a pass that skips the image write still has to clear a stale pin, or
          # provisioning keeps failing with "REMOTE HOST IDENTIFICATION HAS CHANGED" forever.
          if [ -f ${escapeShellArg cfg.provision.knownHostsFile} ]; then
            rm -f ${escapeShellArg cfg.provision.knownHostsFile}
            echo "buildvm: dropped the stale guest host key from ${cfg.provision.knownHostsFile}"
          fi

        fi

        sync
        umount "$MNT"
        losetup -d "$LOOP"
      '';
    };

    # Put the guest's own NixOS config onto the guest.  Until this runs, the machine behind
    # `ssh -p ${toString cfg.sshPort}` is the seed image (platforms/buildvm-bootstrap.nix): a
    # shell with git and sshd, no desktop, no gc, no sudo.  This unit streams ai's deployed nixflakes
    # tree and ai's secrets tree into the guest over ssh, then switches the guest onto that commit -
    # one pass per changed commit rather than a build on every boot.
    #
    # The commit to apply is `provision.targetCommit`, else the one deploy-ai recorded, i.e. the tree
    # the running ai came from.
    systemd.services.buildvm-provision = mkIf cfg.provision.enable {
      description = "Apply the buildvm guest's own NixOS config inside the guest";
      wantedBy = [ "multi-user.target" ];
      after = [ "buildvm.service" ];
      requires = [ "buildvm.service" ];
      unitConfig.ConditionPathExists = cfg.provision.loginKey;
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        # A full guest system build (Xfce, Xvnc, nixVersions.latest) is slow; give it room.
        TimeoutStartSec = "45min";
      };
      path = [ pkgs.git pkgs.openssh pkgs.coreutils pkgs.findutils pkgs.gnutar ];
      script = ''
        USER=${cfg.userName}
        ROOT_USER=${escapeShellArg cfg.provision.activationUser}
        PORT=${toString cfg.sshPort}
        KEY=${escapeShellArg cfg.provision.loginKey}
        WORK=${escapeShellArg cfg.provision.workdir}
        ATTR=${escapeShellArg cfg.provision.flakeAttr}
        TARGET_FILE=${escapeShellArg cfg.provision.targetFile}
        MARKER=${escapeShellArg cfg.provision.markerFile}
        SOURCE=${escapeShellArg (cfg.provision.sourcePath or "")}
        ORIGIN=${escapeShellArg cfg.provision.origin}
        SECRETS_SRC=${escapeShellArg (cfg.provision.secretsSource or "")}
        SECRETS=${escapeShellArg (cfg.provision.secretsDir or "")}
        COMMIT=${escapeShellArg cfg.provision.targetCommit}
        # The snapshot's store name hashes its contents, so it says exactly what this machine runs,
        # whether or not the deploy pointed at a commit.
        SNAPSHOT=$(basename "$SOURCE")
        # Quote the whole flag: unquoted, `OVERRIDE=--override-input private /path` would assign
        # only the first word and then try to run `private` as a command.
        OVERRIDE=${optionalString (cfg.provision.secretsDir != null) (escapeShellArg "--override-input private ${cfg.provision.secretsDir}")}

        # Trust-on-first-use against a file of our own: the guest key is not in root's known_hosts,
        # and buildvm-install deletes this file whenever it writes a fresh image, so a reseed re-trusts
        # automatically while a key that changes under a running guest still fails.
        KNOWN=${escapeShellArg cfg.provision.knownHostsFile}
        mkdir -p "$(dirname "$KNOWN")"
        gssh() {
          ssh -i "$KEY" -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
            -o UserKnownHostsFile="$KNOWN" -p "$PORT" "$USER@127.0.0.1" "$@"
        }

        # Activation runs as root: ${cfg.userName} has no sudo in the guest, and buildvm-install
        # authorizes this same key for ${cfg.provision.activationUser}.
        gssh_root() {
          ssh -i "$KEY" -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
            -o UserKnownHostsFile="$KNOWN" -p "$PORT" "$ROOT_USER@127.0.0.1" "$@"
        }

        # Hands a directory to the build user.  It has to be root doing this: the guest may already
        # hold one of these paths owned by root, because generations before provisioning streamed
        # placed the checkouts while mounting the image, and a root-owned directory makes both tar
        # extraction and `git init` fail for ${cfg.userName} with nothing a builder login can do about
        # it.  Ownership is fixed recursively so a stale tree becomes usable instead of fatal.
        prepare_dir() {
          DEST="$1"
          # Owner only, no group: the guest's build user has no group of its own (NixOS puts
          # isNormalUser in `users` unless told otherwise), so `builder:builder` is not a valid spec and
          # chown would abort the whole run.
          gssh_root "mkdir -p '$DEST' && chown -R '$USER' '$DEST'" \
            || { echo "buildvm-provision: cannot hand $DEST to $USER" >&2; return 1; }
        }

        # Streams a directory's contents into the guest, creating the directory first.  Tar over ssh
        # rather than scp because a tree arrives in one stream, an existing directory is refreshed in
        # place, and everything lands owned by the user sshd logged in as.  A tree that does not arrive
        # must stop the run: switching whatever is already on disk would provision the wrong thing.
        stream_dir() {
          SRC="$1"
          DEST="$2"
          if [ -z "$SRC" ] || [ ! -d "$SRC" ]; then
            echo "buildvm-provision: nothing to stream from $SRC" >&2
            return 1
          fi
          prepare_dir "$DEST" || return 1
          tar -C "$SRC" -cf - . | gssh "tar -xf - -C '$DEST'" \
            || { echo "buildvm-provision: streaming $SRC into $DEST failed" >&2; return 1; }
          # A Nix store tree is read-only (0444 files, 0555 directories) and tar keeps those modes, so a
          # streamed checkout could never be rewritten by git.  Widen the owner's bits on the copy only.
          gssh "chmod -R u+w '$DEST'" \
            || { echo "buildvm-provision: could not make $DEST writable" >&2; return 1; }
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

        # The snapshot decides whether there is anything to do.  A commit sha would not: a deploy from
        # a dirty tree keeps the sha while its contents change, and skipping on the sha alone would
        # leave the guest behind.  With no snapshot there is no identity to compare, and nothing to
        # stream, so this is a configuration error rather than an up-to-date guest.
        if [ -z "$SOURCE" ]; then
          echo "buildvm-provision: provision.sourcePath is unset, so there is nothing to put in the guest" >&2
          exit 1
        fi
        if [ "$(gssh "cat '$MARKER' 2>/dev/null" | tr -d ' \n')" = "$SNAPSHOT" ]; then
          echo "buildvm-provision: guest already at $SNAPSHOT"
          exit 0
        fi

        # Put the tree the running ai came from into the guest.  Streaming it here rather than seeding
        # it in buildvm-install is the point: only provisioning knows what this machine runs.
        stream_dir "$SOURCE" "$WORK" || exit 1
        if [ -n "$SECRETS" ]; then
          stream_dir "$SECRETS_SRC" "$SECRETS" || exit 1
        fi

        # Give the checkout history only when the deploy pointed at a commit.  A dirty deploy records
        # `<sha>-dirty`, which is no commit to check out, and the contents already on disk are what
        # this machine runs; chasing history there would fail the run for nothing.
        TARGET="$COMMIT"
        if [ -z "$TARGET" ] && [ -n "$ORIGIN" ]; then
          TARGET=$(gssh "cat '$TARGET_FILE' 2>/dev/null" | tr -d ' \n')
        fi
        # A dirty deploy records `<sha>-dirty`, which is no commit to check out.
        TARGET=$(printf '%s' "$TARGET" | sed 's/-dirty$//')
        if [ -z "$TARGET" ]; then
          echo "buildvm-provision: no commit recorded, switching the streamed tree as it stands"
        else
          # A streamed tree has no history, and the agent inside the VM needs to push, so give it a
          # remote and fetch through it.  The outbound key grafted into ~/.ssh is what the git host
          # accepts; without that access the streamed tree is still a working flake, it just has no
          # commits behind it, which the check below reports.
          if ! gssh "test -d '$WORK/.git'"; then
            gssh "git init -q '$WORK'" || { echo "buildvm-provision: cannot init $WORK" >&2; exit 1; }
          fi
          gssh "git -C '$WORK' remote add origin '$ORIGIN' 2>/dev/null || git -C '$WORK' remote set-url origin '$ORIGIN'" \
            || echo "buildvm-provision: could not point $WORK at $ORIGIN" >&2
          gssh "GIT_SSH_COMMAND='ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new' git -C '$WORK' fetch --quiet origin" \
            || echo "buildvm-provision: fetch from origin failed, using what the checkout already has"
          if ! gssh "cd '$WORK' && git cat-file -e '$TARGET^{commit}'"; then
            echo "buildvm-provision: $TARGET is not in the guest's checkout" >&2
            exit 1
          fi
          # The streamed tree is the right *contents* but not the right *commit*, and the switch evaluates
          # whatever is on disk, so put the working tree on $TARGET.  --force is needed because the streamed
          # files are untracked and would otherwise block the checkout.
          if ! gssh "git -C '$WORK' checkout --force --quiet --detach '$TARGET'"; then
            echo "buildvm-provision: could not check out $TARGET in $WORK" >&2
            exit 1
          fi
        fi

        echo "buildvm-provision: switching the guest to $SNAPSHOT"
        if ! gssh_root "nixos-rebuild switch --flake '$WORK#$ATTR' $OVERRIDE --accept-flake-config"; then
          echo "buildvm-provision: switch failed; guest left as it is" >&2
          exit 1
        fi

        # A switch changes the bootloader entries, so boot the new system rather than the one this
        # boot came from.  qemu restarts when the guest powers off (buildvm.service Restart=always).
        gssh "echo '$SNAPSHOT' > '$MARKER'"
        gssh_root "reboot" || true
        BACK=0
        for i in $(seq 1 120); do
          sleep 3
          if gssh true; then BACK=1; break; fi
        done
        if [ "$BACK" != 1 ]; then
          echo "buildvm-provision: guest did not come back after the switch" >&2
          exit 1
        fi
        echo "buildvm-provision: guest running its own config at $SNAPSHOT"
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
