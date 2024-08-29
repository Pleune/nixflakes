{ lib, ... }:
{
  options.nixflakes.theme = lib.mkOption { default = "none"; };
  imports = [
    ./wsl.nix
    ./gnome.nix
  ];
}
