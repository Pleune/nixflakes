{ pkgs, username, ... }:
{
  home-manager.users.${username} = {
    home.packages = with pkgs; [
      parsec-bin
      moonlight-qt
      discord
      prismlauncher-qt5
      spotify
      trilium-desktop
      xournalpp
      signal-desktop
      superTux
      superTuxKart
      openttd
      openrct2
      gzdoom
      steam
      krita
      libreoffice
      keepassxc

      winetricks
      wineWow64Packages.unstableFull
    ];

    programs = {
      thunderbird = {
        enable = true;
        profiles.default = {
          isDefault = true;
          withExternalGnupg = true;
        };
      };
      awscli.enable = true;
      firefox = {
        enable = true;
        nativeMessagingHosts = [ pkgs.gnome-browser-connector ];
      };
    };
  };
}
