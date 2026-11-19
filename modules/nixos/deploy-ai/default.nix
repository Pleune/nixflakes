# The deploy gate on ai: the only path from "a commit exists somewhere" to "ai is running it".
#
# There is no repo on ai: deploy-ai is told per call which repo to read, checks that the deployed
# commit is an ancestor of the requested one, and refuses a tree diff outside
# nixflakes.deploy-ai.allowlist.  Two accounts share the build VM's public key: deployer, whose
# forced command is the gate, and root, which is not exposed to the VM.
#
# The other route in is submit: the guest sends a patch on stdin, and deploy-ai vets it against
# nixflakes.deploy-ai.submit.guestOnlyPaths, submit.denylist and policyDigest before applying it.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.nixflakes.deploy-ai;

  # Everything a submitted patch must not be able to change: the gate's own scope, the keys and
  # accounts that reach root, the sudoers and sshd settings that gate them, nix's trusted users, and
  # the buildvm paths a guest-only switch runs on.  deploy-ai recomputes the same shape from the
  # patched tree and refuses a submission whose digest moves, so the rules a patch is vetted against
  # cannot be edited by that patch.  Plain values only -- no derivations, no path checks -- because
  # this is evaluated on every host, and the buildvm options below exist everywhere
  # (`modules/nixos/default.nix` imports that module unconditionally) while carrying real values only
  # on the host that enables it.
  policy = {
    allowlist = cfg.allowlist;
    publicKey = cfg.publicKey;
    buildKey = cfg.buildKey;
    stateDir = cfg.stateDir;
    submitMaxBytes = cfg.submit.maxBytes;
    guestOnlyPaths = cfg.submit.guestOnlyPaths;
    denylist = cfg.submit.denylist;
    # nixpkgs retired security.sudo.wheelWheelGroup, so the wheel policy here is execWheelOnly plus
    # the extraRules the sudo module turns into sudoers lines.
    sudoExtraConfig = config.security.sudo.extraConfig;
    wheelNeedsPassword = config.security.sudo.wheelNeedsPassword;
    execWheelOnly = config.security.sudo.execWheelOnly;
    sudoExtraRules = config.security.sudo.extraRules;
    authorizedKeys = builtins.mapAttrs (_: u: u.openssh.authorizedKeys.keys) config.users.users;
    users = builtins.mapAttrs (_: u: {
      groups = u.extraGroups;
      isNormalUser = u.isNormalUser;
      home = u.home;
    }) config.users.users;
    sshdSettings = config.services.openssh.settings;
    trustedUsers = config.nix.settings.trusted-users;
    buildvm = {
      loginKeysDir = config.nixflakes.virtualisation.buildvm.loginKeysDir;
      guestKeyPath = config.nixflakes.virtualisation.buildvm.guestKeyPath;
      publicKey = config.nixflakes.virtualisation.buildvm.publicKey;
      loginKey = config.nixflakes.virtualisation.buildvm.provision.loginKey;
      activationUser = config.nixflakes.virtualisation.buildvm.provision.activationUser;
    };
  };

  # sshd runs "$SHELL -c <command>", so the client command arrives as $1.  Only a deploy-ai
  # invocation reaches sudo: a guardrail against mistakes, not a sandbox.
  gate = pkgs.writeShellScriptBin "deploy-ai-gate" ''
    case ''${1:-} in
      deploy-ai | 'deploy-ai '*)
        exec ${pkgs.sudo}/bin/sudo -n /run/current-system/sw/bin/deploy-ai ''${1#deploy-ai}
        ;;
      *)
        echo "deploy-ai gate: only 'deploy-ai ...' is accepted here." >&2
        echo "deploy-ai gate: try 'deploy-ai --list' or 'deploy-ai --repo <url> --ref <rev>'." >&2
        exit 1
        ;;
    esac
  '';
in
{
  options.nixflakes.deploy-ai = {
    enable = lib.mkEnableOption "the deploy-ai gate on ai";

    publicKey = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "SSH public key authorized for deployer (the build VM's key).";
    };

    stateDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/deploy-ai";
      description = "Root-owned state: last deployed toplevel, commit, logs, lock.";
    };

    # The flake source that produced the running system; deploy-ai diffs candidates against it.
    deployedSource = lib.mkOption {
      type = with lib.types; nullOr path;
      default = null;
      description = "Store path of the flake source the running ai was built from.";
    };

    deployedCommit = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "Git revision of deployedSource, as recorded at build time.";
    };

    allowlist = lib.mkOption {
      type = with lib.types; listOf str;
      default = [ ];
      example = [
        "platforms/"
        "lib/"
      ];
      description = "Path prefixes the agent may change; deploy-ai reads them from /etc.";
    };

    # Only the key's location goes into /etc; the key itself stays root-owned under the buildvm
    # state dir.
    buildKey = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "Path of the private key deploy-ai uses to reach the build VM and fetch repos.";
    };

    # The other way in: the guest sends a patch over ssh stdin instead of naming a ref.
    submit.enable = lib.mkEnableOption "the submit path, where the build VM sends a patch to the gate on stdin";

    submit.maxBytes = lib.mkOption {
      type = lib.types.int;
      default = 262144;
      description = "Largest patch, in bytes, deploy-ai will read from a submit's stdin.";
    };

    submit.guestOnlyPaths = lib.mkOption {
      type = with lib.types; listOf str;
      default = [ ];
      example = [ "platforms/buildvm.nix" ];
      description = "Path prefixes that belong to the guest alone; a patch inside them switches the guest and leaves ai running.";
    };

    submit.denylist = lib.mkOption {
      type = with lib.types; listOf str;
      default = [
        "modules/nixos/deploy-ai/"
        "pkgs/deploy-ai/"
        "flake.lock"
        "secrets/"
      ];
      description = ''
        Path prefixes no patch may touch at all.  These are the deployment machinery itself -- the
        gate's module, its script, the input lock and the secrets tree -- so a patch can never widen
        the rules it is vetted against.
      '';
    };

    policyDigest = lib.mkOption {
      type = lib.types.str;
      default = builtins.hashString "sha256" (builtins.toJSON policy);
      defaultText = lib.literalExpression ''
        builtins.hashString "sha256" (builtins.toJSON policy)
      '';
      description = "sha256 of the policy a submitted patch may not change; deploy-ai refuses a patch whose digest moves.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.publicKey != "";
        message = "nixflakes.deploy-ai.publicKey is empty; the build VM cannot reach the gate.";
      }
      {
        assertion = cfg.deployedSource != null;
        message = ''
          nixflakes.deploy-ai.deployedSource is unset, so deploy-ai has no baseline to diff
          against and every deploy will be refused.  Pass the flake's own source path.
        '';
      }
      {
        assertion = !cfg.submit.enable || (cfg.publicKey != "" && cfg.submit.guestOnlyPaths != [ ]);
        message = ''
          nixflakes.deploy-ai.submit needs publicKey and submit.guestOnlyPaths: with no key no guest
          can reach the gate, and with no guest-only paths every submitted patch restarts ai.
        '';
      }
    ];

    users.users.deployer = {
      isNormalUser = true;
      home = "/var/lib/deployer";
      # Locked password: key-only, and ssh keys alone cannot run an interactive shell.
      hashedPassword = "*";
      # shellPackage becomes /run/current-system/sw<shellPath>, and writeShellScriptBin sets no
      # shellPath, so the gate is added explicitly.
      shell = gate // {
        shellPath = "/bin/deploy-ai-gate";
      };
      openssh.authorizedKeys.keys = lib.optional (cfg.publicKey != "") cfg.publicKey;
    };

    # Scope of that sudo rule: deploy-ai and nothing else.
    security.sudo.extraConfig = ''
      deployer ALL=(root) NOPASSWD: /run/current-system/sw/bin/deploy-ai
    '';

    # git and curl are what deploy-ai shells out to, and the gate belongs in the system path
    # because /etc/passwd points deployer's shell there.
    environment.systemPackages = [
      pkgs.deploy-ai
      pkgs.git
      pkgs.curl
      gate
    ];

    environment.etc."deploy-ai/allowlist".text = lib.concatStringsSep "\n" cfg.allowlist + "\n";

    environment.etc."deploy-ai/build-key".text = lib.optionalString (cfg.buildKey != "") (
      cfg.buildKey + "\n"
    );

    # The baseline deploy-ai diffs candidate trees against, so a force-reinstall or a rewritten
    # history cannot hide a change to a protected path.
    environment.etc."deploy-ai/deployed-commit".text = cfg.deployedCommit + "\n";

    # The store path, not its contents: deploy-ai reads the baseline out of here.
    environment.etc."deploy-ai/deployed-source".text = lib.optionalString (cfg.deployedSource != null) (
      cfg.deployedSource + "\n"
    );

    # Keeps the baseline store path alive across GC for exactly as long as this generation is
    # reachable, which is how long the diff baseline stays meaningful.
    system.extraDependencies = lib.optionals (cfg.deployedSource != null) [ cfg.deployedSource ];

    # The submit path's rules, read by deploy-ai out of /etc.  Each is a definition that exists only
    # when submit is on, so a host without that path leaves deploy-ai nothing to vet a patch against.
    environment.etc."deploy-ai/submit-max-bytes" = lib.mkIf cfg.submit.enable {
      text = toString cfg.submit.maxBytes + "\n";
    };

    environment.etc."deploy-ai/guest-only-paths" = lib.mkIf cfg.submit.enable {
      text = lib.concatStringsSep "\n" cfg.submit.guestOnlyPaths + "\n";
    };

    environment.etc."deploy-ai/denylist" = lib.mkIf cfg.submit.enable {
      text = lib.concatStringsSep "\n" cfg.submit.denylist + "\n";
    };

    # Computed from the running config, so it moves exactly when a protected setting does.
    environment.etc."deploy-ai/policy-digest" = lib.mkIf cfg.submit.enable {
      text = cfg.policyDigest + "\n";
    };

    # Only the path, as with build-key above.  This is the pair the guest's root accepts; the guest's
    # own outbound key is authorized for its ordinary user only.
    environment.etc."deploy-ai/guest-root-key" = lib.mkIf cfg.submit.enable {
      text = config.nixflakes.virtualisation.buildvm.provision.loginKey + "\n";
    };

    systemd.tmpfiles.rules = [
      "d ${cfg.stateDir} 0700 root root -"
      "d ${cfg.stateDir}/log 0700 root root -"
      # Where a submitted patch lands before it is vetted, so the bytes never sit somewhere world
      # readable and two submissions cannot overwrite each other.
      "d ${cfg.stateDir}/inbox 0700 root root -"
    ];

    # If a guarded reboot happens, roll the recorded generation back before anything else can
    # fail again.  Runs once, and only when rollback-pending says so.
    systemd.services."deploy-ai-boot-rollback" = {
      description = "Roll back a failed deploy-ai switch on boot";
      wantedBy = [ "multi-user.target" ];
      before = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        if [ ! -e ${cfg.stateDir}/rollback-pending ]; then
          exit 0
        fi
        previous=$(cat ${cfg.stateDir}/rollback-previous 2>/dev/null || echo "")
        rm -f ${cfg.stateDir}/rollback-pending
        if [ -z "$previous" ] || [ ! -x "$previous/bin/switch-to-configuration" ]; then
          echo "deploy-ai: no rollback target recorded; leaving this generation alone"
          exit 0
        fi
        echo "deploy-ai: booting after a guarded reboot, switching back to $previous"
        "$previous/bin/switch-to-configuration" switch || true
      '';
    };
  };
}
