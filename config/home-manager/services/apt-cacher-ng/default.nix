{
  lib,
  config,
  pkgs,
  ...
}:
with lib;
let
  cfg = config.nixflakes.services.aptCacherNg;
  cacheDir = "${config.home.homeDirectory}/.cache/apt-cacher-ng";
  logDir = "${cacheDir}/log";
in
{
  options.nixflakes.services.aptCacherNg = {
    enable = mkEnableOption "user-level apt-cacher-ng";
    port = mkOption {
      type = types.port;
      default = 3142;
      description = "Port for the user-level apt-cacher-ng service.";
    };
  };

  config = mkIf cfg.enable {
    systemd.user = {
      services.apt-cacher-ng-clean = {
        Unit = {
          Description = "Clean old apt-cacher-ng cache entries";
        };
        Service = {
          Type = "oneshot";
          ExecStart = ''
            ${pkgs.findutils}/bin/find \
              ${cacheDir} \
              ! -name log \
              -type f \
              -mtime +7 \
              -delete
            ${pkgs.findutils}/bin/find \
              ${cacheDir} \
              -depth \
              ! -path ${logDir} \
              ! -path ${logDir}/* \
              -type d \
              -empty \
              -delete
          '';
        };
      };

      timers.apt-cacher-ng-clean = {
        Unit = {
          Description = "Weekly timer to clean apt-cacher-ng cache";
        };
        Timer = {
          OnCalendar = "Mon 03:00";
          Persistent = true;
        };
        Install = {
          WantedBy = [ "timers.target" ];
        };
      };

      services.apt-cacher-ng = {
        Unit = {
          Description = "apt-cacher-ng (inline config)";
          After = [ "network.target" ];
        };

        Service = {
          ExecStartPre = ''
            ${pkgs.coreutils}/bin/mkdir -p \
              ${logDir}
          '';

          ExecStart = ''
            ${pkgs.apt-cacher-ng}/bin/apt-cacher-ng \
              ForeGround=1 \
              Port=${toString cfg.port} \
              BindAddress=0.0.0.0 \
              CacheDir=${cacheDir} \
              LogDir=${logDir} \
              PassThroughPattern=^(.*):443$
          '';

          Restart = "always";
        };

        Install = {
          WantedBy = [ "default.target" ];
        };
      };
    };
  };
}
