{ username, hostName, NixOS-WSL, ... }:

{
  imports = [ NixOS-WSL.nixosModules.wsl ];
  wsl = {
    enable = true;
    defaultUser = "${username}";
    nativeSystemd = true;
  };

  networking.hostName = "${hostName}";

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

  services.openssh = {
    enable = true;
    settings.PasswordAuthentication = true;
  };
}
