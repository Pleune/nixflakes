{
  config,
  lib,
  packages,
  pkgs,
  ...
}:
with lib;
{
  options.nixflakes.services.incus-backup-rustic = {
    enable = mkEnableOption "Incus backup using rustic";
    rustic-profile = mkOption {
      type = types.str;
      description = "Path to rustic profile, passed with -P";
    };
    timer = mkOption {
      type = types.str;
      description = "when to run the service, in systemd OnCalendar format. Default is daily at 3am";
      default = "*-*-* 03:00:00";
    };
  };
  config =
    let
      cfg = config.nixflakes.services.incus-backup-rustic;
    in
    mkIf cfg.enable {
      systemd.services.incus-backup-rustic = {
        description = "Incus backup using rustic";
        after = [
          "network-online.target"
          "incus.service"
        ];
        wants = [
          "network-online.target"
          "incus.service"
        ];
        serviceConfig = {
          Type = "oneshot";
        };
        script = ''
          ${packages.incus-backup-rustic}/bin/incus-backup-rustic \
            --incus ${config.virtualisation.incus.package}/bin/incus \
            --rustic ${pkgs.rustic}/bin/rustic \
            --profile ${cfg.rustic-profile}
        '';
      };
      systemd.timers.incus-backup-rustic = {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = cfg.timer;
          Unit = "incus-backup-rustic.service";
        };
      };
    };
}
