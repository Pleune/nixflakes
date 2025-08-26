{
  pkgs,
  lib,
  config,
  ...
}:
{
  config = lib.mkMerge [
    (lib.mkIf config.nixflakes.games {
      home.packages = with pkgs; [
        prismlauncher
        superTux
        superTuxKart
        openttd
        openrct2
        gzdoom
        steam
        winetricks
        wineWow64Packages.unstableFull
      ];
    })
    (lib.mkIf config.nixflakes.daily {
      home.packages = with pkgs; [
        parsec-bin
        moonlight-qt
        discord
        prismlauncher
        spotify
        trilium-next-desktop
        xournalpp
        signal-desktop
        krita
        libreoffice
        keepassxc
        vscode
      ];

      services.nextcloud-client = {
        enable = true;
        startInBackground = true;
      };

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
    })
  ];
}
