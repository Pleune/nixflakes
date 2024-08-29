{
  pkgs,
  lib,
  config,
  ...
}:
{
  config = lib.mkIf (config.nixflakes.gui) {
    home.packages = with pkgs; [
      nerdfonts
      noto-fonts
      noto-fonts-cjk
      noto-fonts-emoji
      roboto
      iosevka
    ];
    fonts = {
      fontconfig.defaultFonts = {
        serif = [
          "Roboto Serif"
          "Noto Color Emoji"
        ];
        sansSerif = [
          "Roboto"
          "Noto Color Emoji"
        ];
        emoji = [ "Noto Color Emoji" ];
        monospace = [ "Iosevka" ];
      };
    };
  };
}
