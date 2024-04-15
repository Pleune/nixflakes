{ pkgs, system, username, ... }: {
  home-manager.users.${username} = {
    services.syncthing = {
      enable = true;
      tray = true;
    };
  };
}
