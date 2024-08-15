{
  pkgs,
  nixpkgs,
  nix-ld-rs,
  ...
}:
{
  system = {
    extraSystemBuilderCmds = ''
      ln -sv ${pkgs.path} $out/nixpkgs
    '';
    stateVersion = "23.11";
  };

  nix = {
    package = pkgs.nixVersions.latest;
    nixPath = [ "nixpkgs=/run/current-system/nixpkgs" ];
    settings = {
      experimental-features = [
        "nix-command"
        "flakes"
      ];
      auto-optimise-store = true;
    };

    registry.nixpkgs.flake = nixpkgs;

    gc = {
      automatic = true;
      dates = "weekly";
      options = "--delete-older-than 30d";
    };
  };

  nixpkgs.config.allowUnfree = true;

  home-manager.useUserPackages = true;
  home-manager.useGlobalPkgs = true;

  programs.nix-ld = {
    enable = true;
    package = nix-ld-rs.packages."${pkgs.system}".nix-ld-rs;
  };

  # Does not work with flakes
  programs.command-not-found.enable = false;
}
