{
  pkgs,
  lib,
  inputs,
  self,
  ...
}:
let
  inputsPublic = (builtins.removeAttrs inputs [ "private" ]);
in
{
  # system = {
  #   extraSystemBuilderCmds = ''
  #     ln -sv ${pkgs.path} $out/nixpkgs
  #   '';
  # };

  # put all inputs on nix_path
  environment.etc = lib.mapAttrs' (name: flake: {
    name = "nix/inputs/${name}";
    value.source = flake.outPath;
  }) inputsPublic;
  nix.nixPath = [ "/etc/nix/inputs" ];

  nix = {
    package = pkgs.nixVersions.latest;

    # put all inputs in flake registry
    registry = lib.mapAttrs (n: flake: { inherit flake; }) inputsPublic;
    #nixPath = [ "nixpkgs=/run/current-system/nixpkgs" ];
    #registry.nixpkgs.flake = nixpkgs;

    settings = {
      experimental-features = [
        "nix-command"
        "flakes"
      ];
      auto-optimise-store = true;
      allowed-users = [
        "*"
        "@users"
      ];
      trusted-users = [ "@wheel" ];
    };

    gc = {
      automatic = lib.mkDefault true;
      dates = lib.mkDefault "weekly";
      options = lib.mkDefault "--delete-older-than 30d";
    };
  };

  nixpkgs = {
    config.allowUnfree = true;
  };

  programs.nix-ld.enable = true;

  systemd.services.nix-daemon.serviceConfig.LimitNOFILE = lib.mkForce 40960;

  # Does not work with flakes
  programs.command-not-found.enable = false;

  programs.nh = {
    enable = true;
    flake = self;
  };
}
