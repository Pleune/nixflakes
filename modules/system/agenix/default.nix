{ agenix, pkgs, ... }:
{
  services.openssh.enable = true;
  imports = [ agenix.nixosModules.age ];
  environment.systemPackages = [ agenix.packages.${pkgs.system}.default ];
}
