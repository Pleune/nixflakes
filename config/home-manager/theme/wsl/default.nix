{
  pkgs,
  lib,
  config,
  ...
}:
{
  config = lib.mkIf (config.nixflakes.theme.name == "wsl") {
    gtk = {
      enable = true;
      #theme = {
      #  name = "venta-theme";
      #  package = pkgs.venta;
      #};
      #iconTheme = {
      #  name = "Luna";
      #  package = pkgs.luna-icons;
      #};
    };
    home.packages = [
      pkgs.dconf
      pkgs.lxappearance
    ];
  };
}
