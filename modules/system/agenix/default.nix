{
  agenix,
  lib,
  pkgs,
  config,
  ...
}:
with lib;
{
  imports = [ agenix.nixosModules.age ];
  options.nixflakes.agenix.enable = mkEnableOption "Agenix";
  config = mkIf config.nixflakes.agenix.enable (mkMerge [
    {
      services.openssh.enable = true;
      environment.systemPackages = [ agenix.packages.${pkgs.system}.default ];
    }
  ]);
}
