{
  pkgs,
  lib,
  config,
  ...
}:
{
  config =
    let
      extensions = with pkgs.gnomeExtensions; [
        user-themes
        tray-icons-reloaded
        vitals
        space-bar
        x11-gestures
        wireless-hid
        rounded-window-corners-reborn
        alphabetical-app-grid
        blur-my-shell
        clipboard-indicator
        gsconnect
        hide-top-bar
        home-assistant-extension
      ];
    in
    lib.mkIf (config.nixflakes.theme.name == "gnome") {
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

        gtk4.theme = config.gtk.theme;
      };

      home.sessionVariables.GTK_THEME = "palenight";

      dconf.settings = {
        "org/gnome/desktop/interface" = {
          color-scheme = "prefer-dark";
        };

        "org/gnome/shell" = lib.mkIf config.nixflakes.theme.installGnomeExtensions {
          disable-user-extensions = false;
          enabled-extensions = lib.map (ext: ext.extensionUuid) extensions;
        };
      };

      home.packages =
        with pkgs;
        [
          gnome-tweaks
          palenight-theme
        ]
        ++ lib.optionals config.nixflakes.theme.installGnomeExtensions extensions;

      services.gpg-agent.pinentry.package = lib.mkForce pkgs.pinentry-gnome3;
      programs.firefox.nativeMessagingHosts = [ pkgs.gnome-browser-connector ];
    };
}
