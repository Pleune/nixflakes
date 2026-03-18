{ lib, ... }:
{
  options.nixflakes.theme = {
    name = lib.mkOption { default = "none"; };
    installGnomeExtensions = lib.mkOption { default = true; };
  };
  imports = [
    ./wsl.nix
    ./gnome.nix
  ];
}
