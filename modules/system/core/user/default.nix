{ pkgs, username, home-manager, ... }: {
  imports = [ home-manager.nixosModules.home-manager ];
  users.users.${username} = {
    shell = pkgs.bash;
    isNormalUser = true;
    initialPassword = "temp123";
    extraGroups = [ "wheel" ];
  };
}