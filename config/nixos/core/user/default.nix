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
  imports = [
    home-manager.nixosModules.home-manager

    # just allow for prettier system configurations
    (mkAliasOptionModule [ "nixuserflakes" ] [
      "home-manager"
      "users"
      "${username}"
      "nixflakes"
    ])
  ];

  options.nixflakes = {
    makeUser = mkEnableOption "Create the default user ${username}";
    home-manager.enable = mkEnableOption "home-manager system integration";
  };

  config = {
    nixflakes.home-manager.enable = mkDefault config.nixflakes.makeUser;
    nixflakes.makeUser = mkDefault true;

    users.users.${username} = mkIf config.nixflakes.makeUser {
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
      extraSpecialArgs = inputs // sysdef // {
        nixosStateVersion = config.system.stateVersion;
      };
      users.${username} = "${self}/config/home-manager";
    };
  };
}
