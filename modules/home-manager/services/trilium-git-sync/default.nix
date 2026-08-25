{
  config,
  lib,
  pkgs,
  ...
}:
let
  triliumCfg = config.services.trilium-server;
  cfg = config.services.trilium-git-sync;
  baseUrl =
    if cfg.baseUrl != null then cfg.baseUrl else "http://127.0.0.1:${toString triliumCfg.port}";
  environmentFile =
    if cfg.environmentFile != null then cfg.environmentFile else triliumCfg.environmentFile;
  syncArgs = [
    "--base-url"
    baseUrl
    "--repo-path"
    cfg.repoPath
    "--worktree-root"
    cfg.worktreeRoot
    "--state-dir"
    cfg.stateDir
    "--root-note-id"
    cfg.rootNoteId
  ]
  ++ lib.optionals (cfg.gitUrl != null) [
    "--remote-url"
    cfg.gitUrl
  ]
  ++ lib.optionals (cfg.branch != null) [
    "--branch"
    cfg.branch
  ]
  ++ lib.optionals cfg.useLfs [
    "--use-lfs"
  ];
  syncExec = "${lib.getExe cfg.package} ${lib.escapeShellArgs syncArgs}";
in
{
  options.services.trilium-git-sync = with lib; {
    enable = mkEnableOption "periodic git sync for trilium-server";

    package = mkPackageOption pkgs "trilium-git-sync" { };

    gitUrl = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = ''
        Optional remote git URL for the Trilium export history repo. When unset,
        the sync helper initializes a local repository and skips push/fetch.
      '';
    };

    repoPath = mkOption {
      type = types.str;
      default = "${config.home.homeDirectory}/.local/share/trilium-git.git";
      description = ''
        Persistent bare git repository used to store exported Trilium history.
      '';
    };

    worktreeRoot = mkOption {
      type = types.str;
      default = "${config.home.homeDirectory}/.local/state/trilium-git-sync/worktrees";
      description = ''
        Root directory used for temporary sync worktrees.
      '';
    };

    stateDir = mkOption {
      type = types.str;
      default = "${config.home.homeDirectory}/.local/state/trilium-git-sync";
      description = ''
        State directory for sync locks and cached auth tokens.
      '';
    };

    branch = mkOption {
      type = types.str;
      default = "main";
      description = ''
        Branch to use for sync commits.
      '';
    };

    rootNoteId = mkOption {
      type = types.str;
      default = "root";
      description = ''
        Root note ID to export during sync.
      '';
    };

    baseUrl = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = ''
        Base URL used by the sync helper to reach the running local Trilium server.
        When unset, the helper uses `http://127.0.0.1:<trilium port>`.
      '';
    };

    environmentFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      example = "/run/secrets/trilium-git-sync.env";
      description = ''
        Optional environment file for sync credentials. The helper supports
        `TRILIUM_GIT_SYNC_AUTH_TOKEN`, `TRILIUM_ETAPI_TOKEN`,
        `TRILIUM_GIT_SYNC_PASSWORD`, and `TRILIUM_PASSWORD`.
        When unset, the sync service falls back to `services.trilium-server.environmentFile`.
      '';
    };

    interval = mkOption {
      type = types.str;
      default = "10min";
      description = ''
        How often the user timer should run the sync helper while Trilium is active.
      '';
    };

    useLfs = mkOption {
      type = types.bool;
      default = false;
      description = ''
        When enabled, detect binary exported files and track them with Git LFS
        using generated per-directory `.gitattributes` files next to the files.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = triliumCfg.enable;
        message = "services.trilium-git-sync.enable requires services.trilium-server.enable = true";
      }
    ];

    systemd.user.services.trilium-git-sync = {
      Unit = {
        Description = "Trilium git sync";
        After = [
          "network.target"
          "trilium-server.service"
        ];
        PartOf = [ "trilium-server.service" ];
        RequiresMountsFor = [
          triliumCfg.dataDir
          cfg.repoPath
          cfg.worktreeRoot
          cfg.stateDir
        ];
      };

      Service = {
        Type = "oneshot";
        ExecCondition = "${pkgs.systemd}/bin/systemctl --user is-active --quiet trilium-server.service";
        ExecStart = syncExec;
      }
      // lib.optionalAttrs (environmentFile != null) {
        EnvironmentFile = toString environmentFile;
      };
    };

    systemd.user.timers.trilium-git-sync = {
      Unit = {
        Description = "Periodic Trilium git sync";
        PartOf = [ "trilium-server.service" ];
      };

      Timer = {
        Unit = "trilium-git-sync.service";
        OnBootSec = "5min";
        OnUnitActiveSec = cfg.interval;
        RandomizedDelaySec = "1min";
      };

      Install = {
        WantedBy = [ "timers.target" ];
      };
    };
  };
}
