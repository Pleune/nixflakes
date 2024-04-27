{
  pkgs,
  username,
  lib,
  ...
}:
{
  home-manager.users.${username} = {
    gtk = {
      enable = true;

      iconTheme = {
        name = "Papirus-Dark";
        package = pkgs.papirus-icon-theme;
      };

      theme = {
        name = "palenight";
        package = pkgs.palenight-theme;
      };

      cursorTheme = {
        name = "Numix-Cursor";
        package = pkgs.numix-cursor-theme;
      };

      gtk3.extraConfig = {
        Settings = ''
          gtk-application-prefer-dark-theme=1
        '';
      };

      gtk4.extraConfig = {
        Settings = ''
          gtk-application-prefer-dark-theme=1
        '';
      };
    };

    home.sessionVariables.GTK_THEME = "palenight";

    dconf.settings = {
      "org/gnome/desktop/interface" = {
        color-scheme = "prefer-dark";
      };

      "org/gnome/shell" = {
        disable-user-extensions = false;

        # `gnome-extensions list` for a list
        enabled-extensions = [
          "user-theme@gnome-shell-extensions.gcampax.github.com"
          "trayIconsReloaded@selfmade.pl"
          "Vitals@CoreCoding.com"
          "sound-output-device-chooser@kgshank.net"
          "space-bar@luchrioh"
          "rounded-window-corners@yilozt"
          "wireless-hid@chlumskyvaclav.gmail.com"
          "x11gestures@joseexposito.github.io"
          "AlphabeticalAppGrid@stuarthayhurst"
          "blur-my-shell@aunetx"
          "clipboard-indicator@tudmotu.com"
          "gsconnect@andyholmes.github.io"
          "hidetopbar@mathieu.bidon.ca"
          "hass-gshell@geoph9-on-github"
        ];
      };
    };

    home.packages = with pkgs; [
      gnomeExtensions.user-themes
      gnomeExtensions.tray-icons-reloaded
      gnomeExtensions.vitals
      gnomeExtensions.sound-output-device-chooser
      gnomeExtensions.space-bar
      gnomeExtensions.x11-gestures
      gnomeExtensions.wireless-hid
      gnomeExtensions.rounded-window-corners
      gnomeExtensions.alphabetical-app-grid
      gnomeExtensions.blur-my-shell
      gnomeExtensions.clipboard-indicator
      gnomeExtensions.gsconnect
      gnomeExtensions.hide-top-bar
      gnomeExtensions.home-assistant-extension

      gnome.gnome-tweaks
      palenight-theme
    ];

    services.gpg-agent.pinentryPackage = lib.mkForce pkgs.pinentry-gnome3;
  };
}
