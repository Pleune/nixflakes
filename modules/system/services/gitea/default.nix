{ lib, config, ... }:
with lib;
{
  options.nixflakes.local_gitea.enable = mkEnableOption "Local git server";
  config = mkIf config.nixflakes.local_gitea.enable (mkMerge [
    {
      services.gitea = {
        enable = true;
        appName = "Local Gitea";
        lfs.enable = true;
        settings.server = {
          DOMAIN = "localhost";
          ROOT_URL = "http://localhost:3001/";
          HTTP_PORT = 3001;
        };
      };

    }
  ]);
}
