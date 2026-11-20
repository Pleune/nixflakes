{ config, lib, pkgs, ... }:
with lib;
let
  cfg = config.nixflakes.virtualisation.buildvm;
  # Provisioning always gets its own key; loginKeys add the other consumers (Hermes, tooling).
  loginKeyList =
    lib.optionals cfg.provision.enable [
      { name = "provision"; path = cfg.provision.loginKey; owner = "root"; group = "root"; guestRoot = true; }
    ]
    ++ attrValues cfg.loginKeys;
  # The guest's ordinary user has no sudo, so activation can only run as root: keys the host runs as
  # root are the ones authorized in the guest's /root/.ssh/authorized_keys.
  rootKeyList = filter (k: k.owner == "root" && k.guestRoot) loginKeyList;
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
        and authorized for its ordinary user only.  It is a deploy key for the git host and lives in
        the agent's home, so it is deliberately *not* in the guest's authorized_keys for root: nothing
        that holds it may become root inside the guest.  Empty means "no key".
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
          guestRoot = mkOption {
            type = types.bool;
            default = true;
            description = ''
              Also authorize this key in the guest's `/root/.ssh/authorized_keys`.  A consumer that
              only ever sshes into the guest as its ordinary user should turn this off: an extra root
              login on the VM is a second way in that nothing uses.
            '';
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

      scratchDir = mkOption {
        type = types.str;
        default = "${cfg.provision.workdir}-stream";
        description = ''
          Throwaway directory used only when a deploy points at a commit the guest cannot reach: the
          tree ai runs on is committed there and pushed into the checkout's object store, so provisioning
          can switch to a commit without writing to the checkout itself.  Removed after the push.
        '';
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
          Path on ai copied into secretsDir, normally the `private` input ai evaluated against.  A
          plain copy, so the guest reads the same secrets without a key for the secrets repo.
        '';
      };

      sourcePath = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "/nix/store/...-source";
        description = ''
          Store path on ai holding the nixflakes tree ai was built from, copied into the guest's own
          store and switched by ref.  Placed by provisioning, not seeding: the tree to switch to only
          exists once ai has been deployed.
        '';
      };

      origin = mkOption {
        type = types.str;
        default = "";
        description = ''
          The guest's `origin`: what provisioning fetches commits from and what the agent pushes to,
          using the outbound key buildvm-install grafts into `~${cfg.userName}/.ssh`.  A commit that was
          never pushed has nothing to fetch here, which provisioning warns about and works around by
          recording the tree it copied instead.
        '';
      };

      targetCommit = mkOption {
        type = types.str;
        default = "";
        description = ''
          Commit the guest should be on, normally `self.rev` of ai's deploy.  Empty falls back to the
          file provisioning records in the guest.
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
          Guest file naming the live commit.  `buildvm-provision` writes it after it converges the
          guest onto ai's tree; `deploy-ai --status` only reads it.
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
      restartIfChanged = false;
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
          # Who may log into the guest: the generated login keys, one per consumer.  The outbound
          # keypair is the guest's own credential toward the git host; offering it back inbound would
          # authorize the very key the guest holds, so it is installed as a key file and never added
          # to authorized_keys.
          : > "$SSH_DIR/authorized_keys"
          ${lib.optionalString (loginKeyList != [ ]) ''
          for PUB in ${escapeShellArgs (map (k: "${k.path}.pub") loginKeyList)}; do
            if [ -f "$PUB" ]; then cat "$PUB" >> "$SSH_DIR/authorized_keys"; fi
          done
          ''}
          if [ -n "$PUBLIC_KEY" ]; then
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

          # Root inside the guest, authorized only with the keys ai's own root units hold.  The guest's
          # user has no sudo and its outbound key is not accepted here, so activation reaches root only
          # through ai (deploy-ai / buildvm-provision), never from inside the guest.
          ROOT_DIR="$MNT/root/.ssh"
          mkdir -p "$ROOT_DIR"
          : > "$ROOT_DIR/authorized_keys"
          ${lib.optionalString (rootKeyList != [ ]) ''
          for PUB in ${escapeShellArgs (map (k: "${k.path}.pub") rootKeyList)}; do
            if [ -f "$PUB" ]; then cat "$PUB" >> "$ROOT_DIR/authorized_keys"; fi
          done
          ''}
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
    # sshd, no desktop, no gc, no sudo.  This unit copies ai's nixflakes and secrets trees into the
    # guest - the nixflakes tree into the guest's own store, by path - and switches the guest onto it,
    # one pass per changed snapshot.
    #
    # The commit is `provision.targetCommit`, else what the guest recorded: the tree ai came from.
    systemd.services.buildvm-provision = mkIf cfg.provision.enable {
      description = "Apply the buildvm guest's own NixOS config inside the guest";
      wantedBy = [ "multi-user.target" ];
      after = [ "buildvm.service" ];
      requires = [ "buildvm.service" ];
      # Force switch-to-configuration to restart provisioning whenever the seed image changes,
      # without adding a store reference from this unit.
      restartTriggers = [
        (builtins.unsafeDiscardStringContext "${cfg.image}")
      ];
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
        SCRATCH=${escapeShellArg cfg.provision.scratchDir}
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
        IMAGE_TAG=${escapeShellArg (builtins.unsafeDiscardStringContext (baseNameOf "${cfg.image}"))}
        SNAPSHOT="$(basename "$SOURCE")+$IMAGE_TAG"
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
        # while contents change.  With no snapshot there is nothing to compare or copy, so that is a
        # configuration error, not an up-to-date guest.
        if [ -z "$SOURCE" ]; then
          echo "buildvm-provision: provision.sourcePath is unset, so there is nothing to put in the guest" >&2
          exit 1
        fi
        if [ "$(gssh "cat '$MARKER' 2>/dev/null" | tr -d ' \n')" = "$SNAPSHOT" ]; then
          echo "buildvm-provision: guest already at $SNAPSHOT"
          exit 0
        fi

        # Provisioning never writes the agent's checkout: no stash, no `checkout --force`, no moving
        # `main` or HEAD.  Resetting `main` to the deployed commit used to delete commits the agent had
        # not pushed, and work that never left the guest cannot be recovered.  What moves is the
        # `deployed` tag, and a deploy changes what the guest runs without touching the agent's files.
        #
        # Copy what ai built from into the guest's own store first.  `$SOURCE` is a store path on ai,
        # invisible to the guest, so a switch ref naming it failed with `getting status of
        # "/nix/store/…-nixflakes-source": No such file or directory`; streaming a tarball instead meant
        # committing the copy before anything could build it, which invented a commit that is nobody's
        # deploy.  Store paths are content-addressed, so `nix copy` lands the *same* path in the guest and
        # everything below reads it locally: the seeding, the secrets tree and the switch all refer to one
        # transfer, and the tree is the exact bytes ai evaluated rather than a re-serialized copy of them.
        # `--no-check-sigs` because ai signs no store paths; the guest trusts this host through the ssh key,
        # and a signing key would only be another secret to deploy.  Activation runs as root and the guest's
        # store is writable by root, so the copy goes over the root ssh identity that buildvm-install
        # authorizes.
        PATHS="$SOURCE"
        [ -n "$SECRETS_SRC" ] && PATHS="$PATHS $SECRETS_SRC"
        SSH_OPTS="-i $KEY -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=$KNOWN"
        if ! NIX_SSHOPTS="$SSH_OPTS" nix copy --no-check-sigs --to "ssh-ng://$ROOT_USER@127.0.0.1:$PORT" $PATHS; then
          echo "buildvm-provision: could not copy the tree ai runs on into the guest's store" >&2
          exit 1
        fi

        # The secrets tree is what the agent reads, so it is copied out of the store into its own
        # directory rather than pointed at: a store path is read-only and collectable.
        if [ -n "$SECRETS" ]; then
          prepare_dir "$SECRETS" || exit 1
          if ! gssh "rm -rf '$SECRETS' && mkdir -p '$SECRETS' && cp -a '$SECRETS_SRC/.' '$SECRETS/' && chmod -R u+w '$SECRETS'"; then
            echo "buildvm-provision: could not copy the secrets tree into $SECRETS" >&2
            exit 1
          fi
        fi

        # The commit to apply.  A deploy records `<sha>-dirty`, which is no commit, so the suffix goes
        # off; with nothing recorded, read what the guest says it runs.
        TARGET="$COMMIT"
        if [ -z "$TARGET" ] && [ -n "$TARGET_FILE" ]; then
          TARGET=$(gssh "cat '$TARGET_FILE' 2>/dev/null" | tr -d ' \n')
        fi
        TARGET=$(printf '%s' "$TARGET" | sed 's/-dirty$//')

        if ! gssh "git -C '$WORK' rev-parse --git-dir >/dev/null 2>&1"; then
          # -b main because the skill tells the agent to work on `main`; a `git init` default of
          # `master` would leave the first branch named something nothing else looks at.
          gssh "git init -q -b main '$WORK'" || { echo "buildvm-provision: cannot init $WORK" >&2; exit 1; }
        fi
        if [ -n "$ORIGIN" ]; then
          gssh "git -C '$WORK' remote add origin '$ORIGIN' 2>/dev/null || git -C '$WORK' remote set-url origin '$ORIGIN'" \
            || echo "buildvm-provision: could not point $WORK at $ORIGIN" >&2
          # Commits come from the git host, with the outbound keypair buildvm-install grafted into
          # ~builder/.ssh.  Not fatal: a deploy built from an unpushed commit has nothing on the
          # server, and that tree is published as an object of its own below.  Branches land under
          # `origin/*` so the agent's own branches are untouched; host tags replace the guest's,
          # which is what makes `deployed` mean the commit actually running.  accept-new because the
          # guest has never seen the git host's key.
          gssh "cd '$WORK' && GIT_SSH_COMMAND='ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new' git fetch --quiet --force origin '+refs/heads/*:refs/remotes/origin/*' '+refs/tags/*:refs/tags/*'" \
            || echo "buildvm-provision: could not fetch from $ORIGIN; the guest keeps whatever commits it already had"
        fi

        # An empty checkout is seeded from the tree ai runs on, so the agent starts with something to
        # read and edit.  The copy is local now: the store path arrived above.  This is the only time
        # provisioning writes into $WORK: once the agent has commits of its own, its files are its own.
        SEEDED=""
        if ! gssh "cd '$WORK' && git rev-parse --verify --quiet HEAD >/dev/null"; then
          prepare_dir "$WORK" || exit 1
          if ! gssh "cp -a '$SOURCE/.' '$WORK/' && chmod -R u+w '$WORK' && cd '$WORK' && git add -A && git -c user.name=buildvm-provision -c user.email=buildvm-provision@localhost commit -q -m 'buildvm-provision: seeded from ai'"; then
            echo "buildvm-provision: could not seed $WORK from the tree ai runs on" >&2
            exit 1
          fi
          SEEDED=1
          echo "buildvm-provision: seeded $WORK from the tree ai runs on"
        fi

        # What gets recorded, as a sha.  A commit the guest really has is preferred, because the agent can
        # rebase onto it and push it; a seeded first run reuses the commit that seeded the checkout, so
        # `deployed` and `main` name one tree instead of two commits with the same contents.  Otherwise
        # publish the copied tree as a commit of its own — one scratch tag, no branch moved, no HEAD
        # moved, no file in the checkout changed — because the agent's `git log -1 deployed` has to
        # answer with something.
        REV="$TARGET"
        if [ -n "$REV" ] && ! gssh "cd '$WORK' && git cat-file -e '$REV^{commit}'"; then
          echo "buildvm-provision: $REV is not in the guest's repository; recording the copied tree"
          REV=""
        fi
        if [ -z "$REV" ] && [ "$SEEDED" = 1 ]; then
          REV=$(gssh "git -C '$WORK' rev-parse HEAD" | tr -d ' \n')
        fi
        if [ -z "$REV" ]; then
          # Start empty: a leftover scratch tree would blend an older deploy's files into this one.
          gssh "rm -rf '$SCRATCH'" || true
          prepare_dir "$SCRATCH" || exit 1
          if ! gssh "cp -a '$SOURCE/.' '$SCRATCH/' && chmod -R u+w '$SCRATCH' && cd '$SCRATCH' && git init -q -b provisioned . && git add -A && git -c user.name=buildvm-provision -c user.email=buildvm-provision@localhost commit -q -m 'buildvm-provision: the tree ai runs'" \
            || ! gssh "git -C '$SCRATCH' push --quiet --force '$WORK' HEAD:refs/tags/provisioned-snapshot"; then
            echo "buildvm-provision: could not record the copied tree as a commit in $WORK" >&2
            exit 1
          fi
          REV=$(gssh "git -C '$SCRATCH' rev-parse HEAD" | tr -d ' \n')
          gssh "rm -rf '$SCRATCH'" || true
        fi

        echo "buildvm-provision: switching the guest to $SNAPSHOT"
        SWITCHED=1
        # The path `ai` was built from, now present in the guest's store: the same content, the same ref
        # ai used, and no lock file to write into a read-only store.
        if ! gssh_root "nixos-rebuild switch --flake \"$SOURCE#$ATTR\" $OVERRIDE --accept-flake-config --no-write-lock-file"; then
          echo "buildvm-provision: switch failed; guest left as it is" >&2
          SWITCHED=0
        fi

        [ "$SWITCHED" = 1 ] || exit 1

        # Now, and only now, `deployed` names what the guest runs.  Pushing it to the git host makes the
        # dev box and the guest agree about it; a host that refuses the tag is not fatal, because the
        # guest already runs the commit and its own tag still says so.
        gssh "git -C '$WORK' tag -f deployed '$REV' >/dev/null" \
          || { echo "buildvm-provision: could not tag $REV as deployed" >&2; exit 1; }
        if [ -n "$ORIGIN" ]; then
          gssh "cd '$WORK' && GIT_SSH_COMMAND='ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new' git push --quiet --force origin 'refs/tags/deployed'" \
            || echo "buildvm-provision: could not push the deployed tag to $ORIGIN; the tag in $WORK still names what the guest runs"
        fi
        echo "buildvm-provision: deployed is $REV; $WORK, its main and its working tree were left alone"

        # The record `deploy-ai --status` reads as the guest's own view of what it runs.  Provisioning is
        # the only writer, so the answer always comes from the VM rather than from what ai hoped it ran.
        gssh "printf '%s\\n' '$REV' > '$TARGET_FILE'" \
          || echo "buildvm-provision: could not write $TARGET_FILE; deploy-ai reports the guest as unknown" >&2

        # Tell the agent what happened inside its own checkout: this unit's journal belongs to root on
        # ai, and the guest's own journal dies with the reboot below.  The file stays untracked,
        # because provisioning has no business committing to the agent's branch.
        SUBJECT=$(gssh "git -C '$WORK' log -1 --format=%s '$REV'" | tr -d '\r\n')
        gssh "cat > '$WORK/DEPLOYED.md'" <<NOTE || echo "buildvm-provision: could not write $WORK/DEPLOYED.md" >&2
# What this VM is running

Provisioning wrote this file; it is not part of the repository.

- Commit: $REV
- Tag: deployed
- ai snapshot: $SNAPSHOT
- Provisioned: $(date -u +%Y-%m-%dT%H:%M:%SZ)
- Subject: $SUBJECT

Your checkout, 'main' and HEAD are where you left them: provisioning only tagged
this commit.  Read what is deployed with 'git log -1 deployed', put your work on
top of it with 'git rebase deployed', and send a diff with 'deploy-ai --submit'.
NOTE

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
