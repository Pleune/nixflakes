{ config, lib, pkgs, ... }:
with lib;
let
  cfg = config.nixflakes.virtualisation.buildvm;
  # Provisioning always gets its own key; loginKeys add the other consumers (Hermes, tooling).
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
        Raw block device passed through as the guest's only disk, created by hand
        (docs/buildvm-ai-setup.md section 3).  The guest owns its partition table and filesystem, so
        the host never mounts it.
      '';
    };

    image = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = ''
        make-disk-image output directory whose `*.img` is written onto disk on first boot: a bootable
        raw image with a GPT table and systemd-boot on its ESP.
      '';
    };

    publicKey = mkOption {
      type = types.str;
      default = "";
      description = ''
        Public half of the guest's outbound key (the git host's deploy key), written into its ~/.ssh
        and authorized for the guest's root so units on ai can log in too.  Empty means "no key".
      '';
    };

    privateKeyPath = mkOption {
      type = types.str;
      default = "/var/lib/buildvm/secrets/id_ed25519";
      description = ''
        Private half of the guest's outbound key: agenix-decrypted, grafted in as the build user's ssh
        identity, root-only on the host so it stays 0600.
      '';
    };

    loginKeysDir = mkOption {
      type = types.str;
      default = "/var/lib/buildvm/keys";
      description = ''
        Where buildvm-install generates the host-side logins, one directory per consumer.
      '';
    };

    # ssh ignores a private key anyone else can read (on ai: `Permissions 0640 for
    # '/run/agenix/ai_buildvm_id_ed25519' are too open`), so a shared key is unusable and every
    # consumer gets its own generated pair.
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
        Host keypairs buildvm-install generates on first run and authorizes in the guest, one per user
        that sshes in.  Provisioning has its own option.
      '';
    };

    guestKeyPath = mkOption {
      type = types.str;
      default = cfg.privateKeyPath;
      description = ''
        Where the private half lands inside the guest as builder's ssh key, so the guest authenticates
        outbound with the identity the git host and ai already trust.
      '';
    };

    sshPort = mkOption {
      type = types.port;
      default = 2224;
      description = "Loopback port forwarded to the guest sshd (qemu user-mode networking).";
    };

    # Pinning the NAT subnet is what makes the guest reachable: this qemu build's defaults give it an
    # address in 240.0.0.0/24 with no route and no resolver.  Both guest configs mirror
    # these values as the guest's own configuration.
    netSubnet = mkOption {
      type = types.str;
      default = "10.0.2.0/24";
      description = "NAT subnet qemu hands the guest.";
    };

    netGateway = mkOption {
      type = types.str;
      default = "10.0.2.2";
      description = "NAT gateway, i.e. the guest's default route.";
    };

    netDns = mkOption {
      type = types.str;
      default = "10.0.2.3";
      description = ''
        qemu's built-in resolver, forwarding to ai's.  qemu forwards UDP/53 only from inside its NAT,
        so the guest cannot use ai's nameservers directly.
      '';
    };

    netGuestAddress = mkOption {
      type = types.str;
      default = "10.0.2.15";
      description = ''
        Address qemu hands the guest (its DHCP pool starts here); the guest assigns it statically.
      '';
    };

    netGuestMac = mkOption {
      type = types.str;
      default = "52:54:00:12:34:56";
      description = ''
        MAC of the guest's NIC.  It is pinned because the guest matches its network unit on the MAC:
        predictable interface names are not stable in this VM, and a unit that stops matching leaves
        the card DOWN with no address.
      '';
    };

    # Plain pkgs.OVMF, not OVMFFull: the latter compiles in Secure Boot, which would reject the
    # unsigned systemd-boot NixOS installs, and needs SMM plus a second pflash for features a local
    # build VM has no use for.
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
        Writable OVMF variable store, so the boot entry the guest writes into NVRAM survives a reboot.
        Deleting it resets the firmware to the template above.
      '';
    };

    rootLabel = mkOption {
      type = types.str;
      default = "buildvm";
      description = ''
        ext4 label of the guest's root partition, used to find it inside the image.  Under GPT the root
        is the second partition, not the first.
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
          Where the secrets tree lands in the guest, passed as `--override-input private` so the switch
          reads secrets from disk instead of over ssh.  A copy of the whole `private` input including
          its flake.nix, so the override is a valid flake.
        '';
      };

      secretsSource = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = ''
          Path on ai streamed into secretsDir, normally the `private` input ai evaluated against.  A
          plain copy, so the guest reads the same secrets without a key for the secrets repo.
        '';
      };

      sourcePath = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "/nix/store/...-source";
        description = ''
          Directory on ai holding the nixflakes tree ai was built from, streamed into the guest's
          workdir.  Placed by provisioning, not seeding: the tree to switch to only exists once ai has
          been deployed.
        '';
      };

      origin = mkOption {
        type = types.str;
        default = "";
        description = ''
          The guest's `origin`: what provisioning fetches commits from and what the agent pushes to,
          using the outbound key buildvm-install grafts into `~${cfg.userName}/.ssh`.  A commit that was
          never pushed has nothing to fetch here, which provisioning warns about and works around by
          switching the streamed tree as it stands.
        '';
      };

      targetCommit = mkOption {
        type = types.str;
        default = "";
        description = ''
          Commit the guest should be on, normally `self.rev` of ai's deploy.  Empty falls back to the
          file deploy-ai records in the guest.
        '';
      };

      loginKey = mkOption {
        type = types.str;
        default = "${cfg.loginKeysDir}/provision/id_ed25519";
        description = ''
          Root-owned keypair provisioning sshes with, generated by buildvm-install.  Deliberately not
          the guest's outbound key: ssh needs a key its invoking user owns.
        '';
      };

      activationUser = mkOption {
        type = types.str;
        default = "root";
        description = ''
          Guest user that runs the switch and the reboot.  The ordinary guest user has no sudo, so this
          must be one buildvm-install authorized with a root-owned login key.
        '';
      };

      targetFile = mkOption {
        type = types.str;
        default = "/home/${cfg.userName}/deployed-commit";
        description = ''
          Guest file naming the commit to apply; deploy-ai writes it after each successful deploy.
        '';
      };

      knownHostsFile = mkOption {
        type = types.str;
        default = "/var/lib/buildvm/guest-known_hosts";
        description = ''
          Root-owned known_hosts for the provisioning ssh.  buildvm-install deletes it when it writes a
          fresh image, so a reseed re-trusts the guest's new host key.
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
        GUEST_SSH_TARGET=${escapeShellArg "[127.0.0.1]:${toString cfg.sshPort}"}
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

        # A consumer's own known_hosts, cleared of the guest's entry.  Everyone sshes to
        # 127.0.0.1:<sshPort> with StrictHostKeyChecking=accept-new, which pins whatever it saw
        # first, and every graft pass replaces the guest's sshd host keys, so Hermes, root and
        # deploy-ai would otherwise fail with "REMOTE HOST IDENTIFICATION HAS CHANGED" on the first
        # command after a reseed.  Only this entry goes: a consumer's other pins (the git host on
        # 2223, say) belong to it, not to the guest.
        drop_guest_host_key() {
          # $1 owner, $2 group
          local HOME KN OUT
          HOME=$(getent passwd "$1" 2>/dev/null | cut -d: -f6)
          [ -n "$HOME" ] || return 0
          KN="$HOME/.ssh/known_hosts"
          [ -f "$KN" ] || return 0
          # ssh-keygen -R exits 0 whether or not it removed anything, so its output is the signal.
          OUT=$(ssh-keygen -R "$GUEST_SSH_TARGET" -f "$KN" 2>&1) || return 0
          case "$OUT" in
            # "not found" also contains "found", so check the miss first.
            *"not found"*) return 0 ;;
            *found*)
              chown "$1:$2" "$KN" "$KN.old" 2>/dev/null || true
              echo "buildvm: dropped the stale $GUEST_SSH_TARGET entry from $KN"
              ;;
          esac
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

          for PAIR in ${escapeShellArgs (lib.unique ((map (k: k.owner + ":" + k.group) loginKeyList) ++ [ "root:root" ]))}; do
            drop_guest_host_key "''${PAIR%%:*}" "''${PAIR##*:}"
          done

        fi

        sync
        umount "$MNT"
        losetup -d "$LOOP"
      '';
    };

    # Put the guest's own NixOS config onto the guest.  Until this runs, the machine behind
    # `ssh -p ${toString cfg.sshPort}` is the seed image (platforms/buildvm-bootstrap.nix): git and
    # sshd, no desktop, no gc, no sudo.  This unit streams ai's nixflakes and secrets trees into the
    # guest over ssh and switches the guest onto that commit - one pass per changed snapshot.
    #
    # The commit is `provision.targetCommit`, else what deploy-ai recorded: the tree ai came from.
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
      path = [ pkgs.git pkgs.openssh pkgs.coreutils pkgs.findutils pkgs.gnutar pkgs.gnused ];
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
        # The snapshot's store name hashes its contents, so it identifies what this machine runs even
        # when the deploy pointed at no commit.
        SNAPSHOT=$(basename "$SOURCE")
        # Quote the whole flag: unquoted, `OVERRIDE=--override-input private /path` would bind only the
        # first word and then run `private` as a command.
        OVERRIDE=${optionalString (cfg.provision.secretsDir != null) (escapeShellArg "--override-input private ${cfg.provision.secretsDir}")}

        # Trust-on-first-use against our own file: buildvm-install deletes it on a fresh image, so a
        # reseed re-trusts while a key changing under a running guest still fails.
        KNOWN=${escapeShellArg cfg.provision.knownHostsFile}
        mkdir -p "$(dirname "$KNOWN")"
        gssh() {
          ssh -i "$KEY" -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
            -o UserKnownHostsFile="$KNOWN" -p "$PORT" "$USER@127.0.0.1" "$@"
        }

        # Activation is root: ${cfg.userName} has no sudo, and buildvm-install authorizes this key for
        # ${cfg.provision.activationUser}.
        gssh_root() {
          ssh -i "$KEY" -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
            -o UserKnownHostsFile="$KNOWN" -p "$PORT" "$ROOT_USER@127.0.0.1" "$@"
        }

        # Hand a directory to the build user, as root: an earlier generation may have left it root-owned
        # while mounting the image, and that makes tar extraction and `git init` fail for
        # ${cfg.userName}.  Recursive, so a stale tree becomes usable instead of fatal.
        prepare_dir() {
          DEST="$1"
          # Owner only: the guest's build user has no group of its name (NixOS puts isNormalUser in
          # `users` unless told otherwise), so `builder:builder` would abort the run.
          gssh_root "mkdir -p '$DEST' && chown -R '$USER' '$DEST'" \
            || { echo "buildvm-provision: cannot hand $DEST to $USER" >&2; return 1; }
        }

        # Stream a directory into the guest, creating it first.  Tar over ssh, not scp: one stream, an
        # existing directory refreshed in place, everything owned by the logged-in user.  A tree that
        # fails to arrive stops the run, because switching what is on disk provisions the wrong thing.
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
          # A store tree is 0444/0555 and tar keeps those modes, so git could never rewrite the copy.
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

        # The snapshot decides whether there is work.  A sha would not: a dirty-tree deploy keeps its sha
        # while contents change.  With no snapshot there is nothing to compare or stream, so that is a
        # configuration error, not an up-to-date guest.
        if [ -z "$SOURCE" ]; then
          echo "buildvm-provision: provision.sourcePath is unset, so there is nothing to put in the guest" >&2
          exit 1
        fi
        if [ "$(gssh "cat '$MARKER' 2>/dev/null" | tr -d ' \n')" = "$SNAPSHOT" ]; then
          echo "buildvm-provision: guest already at $SNAPSHOT"
          exit 0
        fi

        # Capture the agent's uncommitted work before streaming: streaming overwrites in place, so
        # stashing afterwards would save the host's tree instead of the agent's edits.
        STASHED=""
        if gssh "git -C '$WORK' rev-parse --git-dir >/dev/null 2>&1" \
           && [ -n "$(gssh "git -C '$WORK' status --porcelain")" ]; then
          if gssh "git -C '$WORK' stash push -u -m 'buildvm pre-provision'"; then
            STASHED=1
            echo "buildvm-provision: stashed the guest's uncommitted changes"
          else
            echo "buildvm-provision: could not stash the guest's uncommitted changes; streaming will overwrite them" >&2
          fi
        fi

        # Put the tree the running ai came from into the guest.  Streaming it here rather than seeding
        # it in buildvm-install is the point: only provisioning knows what this machine runs.
        stream_dir "$SOURCE" "$WORK" || exit 1
        if [ -n "$SECRETS" ]; then
          stream_dir "$SECRETS_SRC" "$SECRETS" || exit 1
        fi

        # The commit to apply.  A deploy records `<sha>-dirty`, which is no commit, so the suffix goes
        # off; with nothing recorded, fall back to what deploy-ai wrote in the guest.
        TARGET="$COMMIT"
        if [ -z "$TARGET" ] && [ -n "$TARGET_FILE" ]; then
          TARGET=$(gssh "cat '$TARGET_FILE' 2>/dev/null" | tr -d ' \n')
        fi
        TARGET=$(printf '%s' "$TARGET" | sed 's/-dirty$//')

        if ! gssh "git -C '$WORK' rev-parse --git-dir >/dev/null 2>&1"; then
          # -b main because the rebase logic below only speaks of `main`; a `git init` default of
          # `master` would leave the first branch named something the rest of the script never looks at.
          gssh "git init -q -b main '$WORK'" || { echo "buildvm-provision: cannot init $WORK" >&2; exit 1; }
        fi
        if [ -n "$ORIGIN" ]; then
          gssh "git -C '$WORK' remote add origin '$ORIGIN' 2>/dev/null || git -C '$WORK' remote set-url origin '$ORIGIN'" \
            || echo "buildvm-provision: could not point $WORK at $ORIGIN" >&2
          # Commits come from the git host, with the outbound keypair buildvm-install grafted into
          # ~builder/.ssh.  Not fatal: a deploy built from an unpushed commit has nothing on the
          # server, and the switch then runs on the streamed contents.  Branches land under
          # `origin/*` so the agent's own branches are untouched; host tags replace the guest's,
          # which is what makes `deployed` mean the commit actually running.  accept-new because the
          # guest has never seen the git host's key.
          gssh "cd '$WORK' && GIT_SSH_COMMAND='ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new' git fetch --quiet --force origin '+refs/heads/*:refs/remotes/origin/*' '+refs/tags/*:refs/tags/*'" \
            || echo "buildvm-provision: could not fetch from $ORIGIN; the guest keeps whatever commits it already had"
        fi

        # Point the guest's branch at the deploy.  The guest's own commits are snapshots of trees this
        # service streamed, so they share no history with the host's repository and cannot be rebased
        # onto it; `main` therefore always ends up at the deployed commit, and whatever the guest had
        # that is not this deploy is kept on a tag instead of dropped.
        if [ -z "$TARGET" ]; then
          echo "buildvm-provision: no commit recorded; the guest runs the streamed tree"
        elif ! gssh "cd '$WORK' && git cat-file -e '$TARGET^{commit}'"; then
          echo "buildvm-provision: $TARGET is not in the guest's checkout; the guest runs the streamed tree"
          TARGET=""
        else
          gssh "git -C '$WORK' tag -f deployed '$TARGET' >/dev/null" \
            || { echo "buildvm-provision: could not tag $TARGET as deployed" >&2; exit 1; }
          if gssh "git -C '$WORK' show-ref --verify --quiet refs/heads/main"; then
            OLD=$(gssh "git -C '$WORK' rev-parse main" | tr -d ' \n')
            if [ "$OLD" != "$TARGET" ]; then
              gssh "git -C '$WORK' tag -f agent-work '$OLD' >/dev/null" || true
              echo "buildvm-provision: the guest's previous main is kept on tag agent-work ($OLD)"
            fi
          fi
          gssh "git -C '$WORK' update-ref refs/heads/main '$TARGET'" \
            || { echo "buildvm-provision: could not point main at $TARGET" >&2; exit 1; }
          # nix builds the commit `main` points at, so the worktree has to match it rather than keep
          # whatever the stream left behind.  --force because the streamed files are dirty/untracked.
          if ! gssh "git -C '$WORK' checkout --force --quiet main"; then
            echo "buildvm-provision: could not check out main in $WORK" >&2
            exit 1
          fi
        fi

        # nix builds a git flake from *tracked* files: committed content plus modifications to tracked
        # files, while an untracked file is invisible to it (nix says so: `git -C <dir> add -N <file>`).
        # So the tree this deploy streamed only reaches the guest once it is tracked, which means
        # committing it.  The commit is deliberately untagged - `deployed` names the commit the git host
        # has, and a sha invented inside the guest would not be the sha the dev box has.
        if [ -n "$(gssh "cd '$WORK' && git status --porcelain")" ]; then
          gssh "cd '$WORK' && git add -A && git -c user.name=buildvm-provision -c user.email=buildvm-provision@localhost commit -q -m 'buildvm-provision: streamed tree'" \
            || { echo "buildvm-provision: could not commit the streamed tree in $WORK" >&2; exit 1; }
        fi

        echo "buildvm-provision: switching the guest to $SNAPSHOT"
        # The switch runs as root (the guest's user has no sudo) while $WORK belongs to $USER, and
        # libgit2 refuses a repository owned by someone else: the first deploy after `git init` died
        # with `repository path '/home/builder/nixflakes' is not owned by current user (libgit2 error
        # code = 7)`.  Naming the one path in root's git config is enough; `safe.directory '*'` would
        # make root accept any foreign repository on the box.
        gssh_root "git config --global --replace-all safe.directory '$WORK'" \
          || echo "buildvm-provision: could not mark $WORK as safe for $ROOT_USER; the switch will fail" >&2
        SWITCHED=1
        if ! gssh_root "nixos-rebuild switch --flake '$WORK#$ATTR' $OVERRIDE --accept-flake-config"; then
          echo "buildvm-provision: switch failed; guest left as it is" >&2
          SWITCHED=0
        fi

        # Put the agent's own edits back, and only after the switch: nix would otherwise build them into
        # the running config, so half-finished work could take down the guest's own rebuild.  A stash
        # that no longer applies stays in the stash (the agent finds it with `git stash list`) and the
        # tree is reset, because leaving a half-merged working tree is worse than losing the edits.
        if [ "$STASHED" = 1 ]; then
          if ! gssh "git -C '$WORK' stash apply 'stash@{0}'"; then
            echo "buildvm-provision: the guest's stashed changes do not apply onto the applied tree; kept in the stash" >&2
            gssh "git -C '$WORK' checkout --force --quiet ." || true
          fi
        fi

        [ "$SWITCHED" = 1 ] || exit 1

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
            -netdev user,id=n0,net=${cfg.netSubnet},host=${cfg.netGateway},dns=${cfg.netDns},dhcpstart=${cfg.netGuestAddress},hostfwd=tcp:127.0.0.1:${toString cfg.sshPort}-:22 \
            -device virtio-net-pci,netdev=n0,mac=${cfg.netGuestMac} \
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
