{ pkgs, username, ... }: {
  system = {
    extraSystemBuilderCmds = ''
      ln -sv ${pkgs.path} $out/nixpkgs
    '';
    stateVersion = "23.11";
  };

  nix = {
    #package = pkgs.nixVersions.nix_2_21;
    #nixPath = [ "nixpkgs=/run/current-system/nixpkgs" ];
    settings.experimental-features = [ "nix-command" "flakes" ];
  };

  programs.nix-ld.enable = true;
  nixpkgs.config.allowUnfree = true;
}
