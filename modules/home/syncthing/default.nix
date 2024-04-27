{ username, pkgs, ... }:
{
  home-manager.users.${username} = {
    home.packages = with pkgs; [ gnomeExtensions.syncthing-indicator ];
    dconf.settings."org/gnome/shell".enabled-extensions = [ "syncthing@gnome.2nv2u.com" ];

    # fix tray not launching due to not managing xsession with HM
    systemd.user.targets.tray = {
      Unit = {
        Description = "Home Manager System Tray";
        Requires = [ "graphical-session-pre.target" ];
      };
    };

    services.syncthing = {
      enable = true;
    };
  };
}
