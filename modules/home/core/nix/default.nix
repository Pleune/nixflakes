{
  home-manager,
  pkgs,
  username,
  ...
}:
{
  nixpkgs.config.allowUnfree = true;
  home-manager.users.${username} = {
    home.stateVersion = "23.11";
    nixpkgs.config.allowUnfree = true;
  };
}
