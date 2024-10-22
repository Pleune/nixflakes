{ lib, ... }:
{
  programs.starship = {
    enable = true;
    enableTransience = true;
    settings = lib.importTOML ./starship.toml;
  };
}
