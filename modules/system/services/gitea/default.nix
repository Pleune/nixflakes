{ pkgs, ... }: {
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