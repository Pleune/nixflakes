{
  pkgs,
  system,
  username,
  ...
}:
{
  home-manager.users.${username} = {
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
      pkgs.firefox
      pkgs.lxappearance
      pkgs.venta
    ];
  };
}
