{
  config,
  lib,
  packages,
  pkgs,
  ...
}:
with lib;
{
  options.nixflakes.services.wake-on-lan-api = {
    enable = mkEnableOption "Wake on LAN api by rix1337";
    user = mkOption {
      type = types.str;
      description = "User to run service as. Is not created if changed from default.";
      default = "wol_api";
    };
    group = mkOption {
      type = types.str;
      description = "Group to run service as. Is not created if changed from default.";
      default = "wol_api";
    };
    port = mkOption {
      type = types.int;
      description = "Port to run the Wake on LAN API on.";
      default = 8080;
    };
  };
  config =
    let
      cfg = config.nixflakes.services.wake-on-lan-api;
    in
    mkIf cfg.enable {
      users.users."${cfg.user}" = mkIf (cfg.user == "wol_api") {
        isSystemUser = true;
        description = "user for wake-on-lan-api.service";
        group = cfg.group;
      };

      users.groups.wol_api = mkIf (cfg.user == "wol_api") { };

      systemd.services.wake-on-lan-api = {
        description = "Wake on LAN API";
        after = [
          "network-online.target"
        ];
        wants = [
          "network-online.target"
        ];
        wantedBy = [
          "multi-user.target"
        ];
        serviceConfig = {
          Type = "simple";
          User = cfg.user;
        };
        script = ''
          ${packages.wol_api}/bin/wol_api --port ${toString cfg.port}
        '';
      };
    };
}
