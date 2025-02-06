{
  lib,
  config,
  nixvim,
  pkgs,
  ...
}:
with lib;
{
  imports = [ nixvim.homeManagerModules.nixvim ];
  options.nixflakes.programs.mitchvim.enable = mkEnableOption "Mitch neovim";
  config = mkIf config.nixflakes.programs.mitchvim.enable {
    programs.nixvim = {
      enable = true;
      defaultEditor = true;
      vimdiffAlias = true;
      nixpkgs.useGlobalPackages = true;
    } // (import ./options.nix { inherit pkgs; });
  };
}
