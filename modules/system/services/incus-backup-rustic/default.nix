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
    user = mkOption {
      type = types.str;
      description = "User to run backup service as. Is not created if changed from default. Must be a member of the group 'incus', and be able to access the rustic profile.";
      default = "incus-backup-rustic";
    };
    allow-sudo = mkOption {
      type = types.bool;
      description = "Allow the script to use sudo, for backing up custom zfs volumes";
      default = true;
    };
  };
  config =
    let
      cfg = config.nixflakes.services.incus-backup-rustic;
    in
    mkIf cfg.enable {
      users.users."${cfg.user}" = mkIf (cfg.user == "incus-backup-rustic") {
        isSystemUser = true;
        description = "user for incus-backup-rustic.service";
        group = "incus-admin";
      };

      security.sudo = mkIf (cfg.user != "root") {
        enable = true;
        extraRules = [
          {
            users = [ cfg.user ];
            commands = [
              {
                command = "${pkgs.util-linux}/bin/mount";
                options = [ "NOPASSWD" ];
              }
              {
                command = "${pkgs.util-linux}/bin/umount";
                options = [ "NOPASSWD" ];
              }
              {
                command = "${pkgs.rustic}/bin/rustic";
                options = [ "NOPASSWD" ];
              }
            ];
          }
        ];
      };

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
          User = cfg.user;
        };
        script = ''
          ${packages.incus-backup-rustic}/bin/incus-backup-rustic \
            --incus ${config.virtualisation.incus.package}/bin/incus \
            --rustic ${pkgs.rustic}/bin/rustic \
            --mount ${pkgs.util-linux}/bin/mount \
            --umount ${pkgs.util-linux}/bin/umount \
            --sudo /run/wrappers/bin/sudo \
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
