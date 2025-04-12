{
  pkgs,
  lib,
  config,
  ...
}:
{
  config = lib.mkIf (config.nixflakes.gui) {
    home.packages = with pkgs; [
      # TODO: add back nerdfonts
      noto-fonts
      noto-fonts-cjk-sans
      noto-fonts-emoji
      roboto
      nerd-fonts.iosevka
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
        monospace = [ "Iosevka Nerd Font" ];
      };
    };
  };
}
