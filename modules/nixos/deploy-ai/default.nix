# The deploy gate on ai: the only path from "a commit exists somewhere" to "ai is running it".
#
# There is no repo on ai: deploy-ai is told per call which repo to read, checks that the deployed
# commit is an ancestor of the requested one, and refuses a tree diff outside
# nixflakes.deploy-ai.allowlist.  Two accounts share the build VM's public key: deployer, whose
# forced command is the gate, and root, which is not exposed to the VM.
{ config, lib, pkgs, ... }:
let
  cfg = config.nixflakes.deploy-ai;

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
      example = [ "platforms/" "lib/" ];
      description = "Path prefixes the agent may change; deploy-ai reads them from /etc.";
    };

    # Only the key's location goes into /etc; the key itself stays root-owned under the buildvm
    # state dir.
    buildKey = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "Path of the private key deploy-ai uses to reach the build VM and fetch repos.";
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
    ];

    users.users.deployer = {
      isNormalUser = true;
      home = "/var/lib/deployer";
      # Locked password: key-only, and ssh keys alone cannot run an interactive shell.
      hashedPassword = "*";
      # shellPackage becomes /run/current-system/sw<shellPath>, and writeShellScriptBin sets no
      # shellPath, so the gate is added explicitly.
      shell = gate // { shellPath = "/bin/deploy-ai-gate"; };
      openssh.authorizedKeys.keys = lib.optional (cfg.publicKey != "") cfg.publicKey;
    };

    # Scope of that sudo rule: deploy-ai and nothing else.
    security.sudo.extraConfig = ''
      deployer ALL=(root) NOPASSWD: /run/current-system/sw/bin/deploy-ai
    '';

    # git and curl are what deploy-ai shells out to, and the gate belongs in the system path
    # because /etc/passwd points deployer's shell there.
    environment.systemPackages = [ pkgs.deploy-ai pkgs.git pkgs.curl gate ];

    environment.etc."deploy-ai/allowlist".text =
      lib.concatStringsSep "\n" cfg.allowlist + "\n";

    environment.etc."deploy-ai/build-key".text = lib.optionalString (cfg.buildKey != "") (
      cfg.buildKey + "\n"
    );

    # The baseline deploy-ai diffs candidate trees against, so a force-reinstall or a rewritten
    # history cannot hide a change to a protected path.
    environment.etc."deploy-ai/deployed-commit".text = cfg.deployedCommit + "\n";

    # The store path, not its contents: deploy-ai reads the baseline out of here.
    environment.etc."deploy-ai/deployed-source".text =
      lib.optionalString (cfg.deployedSource != null) (cfg.deployedSource + "\n");

    # Keeps the baseline store path alive across GC for exactly as long as this generation is
    # reachable, which is how long the diff baseline stays meaningful.
    system.extraDependencies =
      lib.optionals (cfg.deployedSource != null) [ cfg.deployedSource ];

    systemd.tmpfiles.rules = [
      "d ${cfg.stateDir} 0700 root root -"
      "d ${cfg.stateDir}/log 0700 root root -"
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
