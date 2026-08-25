{
  lib,
  config,
  ...
}:
with lib;
let
  cfg = config.nixflakes.services.podman;
  aptCacherNgEnabled = config.nixflakes.services.aptCacherNg.enable;
  proxyUrl = "http://host.containers.internal:${toString config.nixflakes.services.aptCacherNg.port}";
in
{
  options.nixflakes.services.podman = {
    enable = mkEnableOption "Podman";

    enableSocket = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Enable the Podman API socket (rootless).
        Provides a Docker-compatible socket at $XDG_RUNTIME_DIR/podman/podman.sock.
      '';
    };
  };

  config = mkIf cfg.enable (mkMerge [
    {
      services.podman.enable = true;
    }
    (mkIf cfg.enableSocket {
      # Expose the package-provided Podman user units to systemd, then enable
      # the package-provided socket via the normal wants symlink. This avoids
      # duplicating podman's upstream unit definitions in our config.
      systemd.user.packages = [ config.services.podman.package ];

      xdg.configFile."systemd/user/sockets.target.wants/podman.socket".source =
        "${config.services.podman.package}/share/systemd/user/podman.socket";
    })
    (mkIf aptCacherNgEnabled {
      services.podman.settings.containers = {
        http_proxy = true;
        env = [
          "http_proxy=${proxyUrl}"
          "https_proxy=${proxyUrl}"
        ];
      };
    })
  ]);
}
