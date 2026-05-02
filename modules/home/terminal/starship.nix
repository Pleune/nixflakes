{ lib, self, ... }:
{
  programs.starship = {
    enable = true;
    enableTransience = true;
    settings = lib.importTOML (self + "/config/starship.toml");
  };
}
