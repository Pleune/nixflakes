{ lib, config, ... }:
with lib;
{
  options.nixflakes.services.localGit.enable = mkEnableOption "Local git server";
  config = mkIf config.nixflakes.services.localGit.enable (mkMerge [
    {
      services.forgejo = {
        enable = true;
        appName = "Local Forgejo";
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
