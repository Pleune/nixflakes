{
  pkgs,
  home-manager,
  username,
  root,
  inputs,
  sysdef,
  ...
}:
{
  users.users.${username} = {
    shell = pkgs.bash;
    isNormalUser = true;
    initialPassword = "temp123";
    extraGroups = [
      "wheel"
      "dialout"
    ];
  };

  imports = [ home-manager.nixosModules.home-manager ];
  home-manager = {
    useUserPackages = true;
    useGlobalPkgs = true;
    extraSpecialArgs = inputs // sysdef;
    users.${username} = "${root}/modules/home";
  };
}
