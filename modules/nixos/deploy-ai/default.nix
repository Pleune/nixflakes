# The deploy gate on ai: the only path from "a commit exists somewhere" to "ai is running it".
#
# There is no repo on ai.  deploy-ai is told, per call, which repo to read (--repo), checks that
# the deployed commit is an ancestor of the requested one, and that the tree diff against the
# source that produced the running system stays inside the allowlist.
#
# Two accounts, both keyed with the same public key the build VM holds:
#   deployer  forced command that only runs deploy-ai (via sudo), for the agent's terminal.
#   root      not exposed; deploys from outside the VM go through the normal ssh.
{ config, lib, pkgs, ... }:
let
  cfg = config.nixflakes.deploy-ai;

  # sshd runs "$SHELL -c <command>", so the whole client command arrives as $1.  Accept only a
  # deploy-ai invocation and hand it to sudo; everything else is refused.  This is a guardrail
  # against mistakes, not a sandbox: the agent could only ever reach what sudo allows.
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

    # The flake source that produced the running system, pinned by system.extraDependencies so it
    # cannot be collected.  This is the baseline deploy-ai diffs candidates against.
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

    # Only the *location* of the key goes into /etc; the key itself stays root-owned under
    # nixflakes.virtualisation.buildvm.stateDir.
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
      # NixOS turns a shellPackage into /run/current-system/sw<shellPath>, so the gate has to be an
      # installed executable, not a bare store directory; writeShellScriptBin does not set
      # shellPath, hence the explicit addition.
      shell = gate // { shellPath = "/bin/deploy-ai-gate"; };
      openssh.authorizedKeys.keys = lib.optional (cfg.publicKey != "") cfg.publicKey;
    };

    # Scope of that sudo rule: deploy-ai and nothing else.
    security.sudo.extraConfig = ''
      deployer ALL=(root) NOPASSWD: /run/current-system/sw/bin/deploy-ai
    '';

    # git and curl are what deploy-ai shells out to; the gate belongs in the system path because
    # that is where /etc/passwd points deployer's shell.
    environment.systemPackages = [ pkgs.deploy-ai pkgs.git pkgs.curl gate ];

    environment.etc."deploy-ai/allowlist".text =
      lib.concatStringsSep "\n" cfg.allowlist + "\n";

    environment.etc."deploy-ai/build-key".text = lib.optionalString (cfg.buildKey != "") (
      cfg.buildKey + "\n"
    );

    # The baseline: what the running system was built from, and its revision.  deploy-ai diffs
    # candidate trees against this, so a force-reinstall or a rewritten history cannot hide a
    # change to a protected path.
    environment.etc."deploy-ai/deployed-commit".text = cfg.deployedCommit + "\n";

    # The store path, not its contents: deploy-ai reads the baseline out of here.
    environment.etc."deploy-ai/deployed-source".text =
      lib.optionalString (cfg.deployedSource != null) (cfg.deployedSource + "\n");

    # Holding this in the system's dependencies keeps the store path alive across GC for as long
    # as this generation is reachable (current or rollback), which is exactly as long as the diff
    # baseline is meaningful.
    system.extraDependencies =
      lib.optionals (cfg.deployedSource != null) [ cfg.deployedSource ];

    systemd.tmpfiles.rules = [
      "d ${cfg.stateDir} 0700 root root -"
      "d ${cfg.stateDir}/log 0700 root root -"
    ];

    # On a boot where deploy-ai left the timed reboot guard armed, roll the recorded previous
    # generation back before anything else can fail again.  Runs once, and only when told to.
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
