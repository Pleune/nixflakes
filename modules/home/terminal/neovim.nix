{
  lib,
  config,
  nixvim,
  pkgs,
  self,
  ...
}:
with lib;
{
  imports = [ nixvim.homeModules.nixvim ];
  options.nixflakes.programs.mitchvim.enable = mkEnableOption "Mitch neovim";
  config = mkIf config.nixflakes.programs.mitchvim.enable {
    programs.nixvim = {
      enable = true;
      defaultEditor = true;
      vimdiffAlias = true;
      nixpkgs.useGlobalPackages = true;
    } // (import (self + "/config/nixvim.nix") { inherit pkgs; });
  };
}
