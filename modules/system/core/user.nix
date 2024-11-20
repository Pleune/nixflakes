{
  pkgs,
  lib,
  home-manager,
  username,
  inputs,
  sysdef,
  config,
  self,
  ...
}:
with lib;
{
  imports = [ home-manager.nixosModules.home-manager ];

  options.nixflakes = {
    home-manager.enable = mkEnableOption "home-manager system integration";
  };

  config = {

    nixflakes.home-manager.enable = mkDefault true;

    users.users.${username} = {
      shell = pkgs.bash;
      isNormalUser = true;
      initialPassword = "temp123";
      extraGroups = [
        "wheel"
        "dialout"
      ];
    };

    home-manager = mkIf config.nixflakes.home-manager.enable {
      useUserPackages = true;
      useGlobalPkgs = true;
      extraSpecialArgs = inputs // sysdef;
      users.${username} = "${self}/modules/home";
    };
  };
}
