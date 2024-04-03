{ home-manager, pkgs, username, ... }: {
  nixpkgs.config.allowUnfree = true;
  home-manager.users.${username} = {
    # The home.stateVersion option does not have a default and must be set
    home.stateVersion = "23.11";
    nixpkgs.config.allowUnfree = true;
  };
}
