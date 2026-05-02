{
  lib,
  config,
  ...
}:
with lib;
let
  aptCacherNgEnabled = config.nixflakes.services.aptCacherNg.enable;
  proxyUrl = "http://host.containers.internal:${toString config.nixflakes.services.aptCacherNg.port}";
in
{
  options.nixflakes.services.podman.enable = mkEnableOption "Podman";

  config = mkIf config.nixflakes.services.podman.enable (mkMerge [
    {
      services.podman.enable = true;
    }
    (mkIf aptCacherNgEnabled {
      services.podman.settings.containers = {
        http_proxy = true;
        env = [
          "http_proxy=${proxyUrl}"
          "https_proxy=${proxyUrl}"
        ];
      };

      programs.fish.functions.podman = ''
        set -lx http_proxy ${proxyUrl}
        set -lx https_proxy ${proxyUrl}
        command podman $argv
      '';
    })
  ]);
}
