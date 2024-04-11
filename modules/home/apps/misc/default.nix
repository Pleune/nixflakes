{ pkgs, home-manager, username, ... }: {
  home-manager.users.${username} = {
    home.packages = with pkgs; [
      parsec-bin
      moonlight-qt
      discord
      prismlauncher-qt5
      spotify
      trilium-desktop
      xournal
      signal-desktop
      firefox
    ];
  };
}
