{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.trilium-server;
  configIni = pkgs.writeText "trilium-config.ini" ''
    [General]
    instanceName=${cfg.instanceName}
    noDesktopIcon=true
    noBackup=${lib.boolToString cfg.noBackup}
    noAuthentication=${lib.boolToString cfg.noAuthentication}

    [Network]
    host=${cfg.bindAddress}
    port=${toString cfg.port}
    https=false
  '';
  prepareScript = pkgs.writeShellScript "trilium-server-prepare" ''
    set -eu

    mkdir -p ${lib.escapeShellArg cfg.dataDir}
    ln -sfn ${lib.escapeShellArg configIni} ${lib.escapeShellArg "${cfg.dataDir}/config.ini"}
  '';
in
{
  options.services.trilium-server = with lib; {
    enable = mkEnableOption "trilium-server";

    package = mkPackageOption pkgs "trilium-server" { };

    dataDir = mkOption {
      type = types.str;
      default = "${config.home.homeDirectory}/.local/share/trilium";
      description = ''
        Directory storing the notes database and configuration.
      '';
    };

    environmentFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      example = "/run/secrets/trilium.env";
      description = ''
        Optional environment file loaded by the user service.
      '';
    };

    instanceName = mkOption {
      type = types.str;
      default = "Trilium";
      description = ''
        Instance name used to distinguish between different instances.
      '';
    };

    noBackup = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Disable periodic database backups.
      '';
    };

    noAuthentication = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Disable password authentication for the web frontend.
      '';
    };

    bindAddress = mkOption {
      type = types.str;
      default = "127.0.0.1";
      description = ''
        Address for the Trilium server to bind to.
      '';
    };

    port = mkOption {
      type = types.port;
      default = 8080;
      description = ''
        Port for the Trilium server to bind to.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.user.services.trilium-server = {
      Unit = {
        Description = "Trilium Notes server";
        After = [ "network.target" ];
        RequiresMountsFor = [ cfg.dataDir ];
      };

      Service = {
        ExecStartPre = "${prepareScript}";
        ExecStart = lib.getExe cfg.package;
        Environment = [ "TRILIUM_DATA_DIR=\"${cfg.dataDir}\"" ];
        Restart = "on-failure";
      }
      // lib.optionalAttrs (cfg.environmentFile != null) {
        EnvironmentFile = toString cfg.environmentFile;
      };

      Install = {
        WantedBy = [ "default.target" ];
      };
    };
  };
}
