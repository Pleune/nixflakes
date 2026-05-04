{
  hostName,
  pkgs,
  lib,
  inputs,
  self,
  ...
}:
let
  inputsPublic = (removeAttrs inputs [ "private" ]);
in
{
  # system = {
  #   extraSystemBuilderCmds = ''
  #     ln -sv ${pkgs.path} $out/nixpkgs
  #   '';
  # };

  networking.hostName = "${hostName}";

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

      extra-substituters = [
        "https://nix.pleunetowne.com"
        "https://nix-community.cachix.org"
        "https://cuda-maintainers.cachix.org"
        "https://numtide.cachix.org"
      ];
      trusted-substituters = [
        "https://nix.pleunetowne.com"
        "https://nix-community.cachix.org"
        "https://cuda-maintainers.cachix.org"
        "https://numtide.cachix.org"
        "https://ros.cachix.org"
      ];
      extra-trusted-public-keys = [
        "git-runner1:uBsNvsIl85z2ApqcH88hIhc4F0uGl5vFmt5ohr3NZDA="
        "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
        "cuda-maintainers.cachix.org-1:0dq3bujKpuEPMCX6U4WylrUDZ9JyUG0VpVZa7CNfq5E="
        "numtide.cachix.org-1:2ps1kLBUWjxIneOy1Ik6cQjb41X0iXVXeHigGmycPPE="
        "ros.cachix.org-1:dSyZxI8geDCJrwgvCOHDoAfOm5sV1wCPjBkKL+38Rvo="
      ];
    };

    gc = {
      automatic = lib.mkDefault true;
      dates = lib.mkDefault "weekly";
      options = lib.mkDefault "--delete-older-than 30d";
    };
  };

  nixpkgs = {
    config.allowUnfree = true;
    overlays = [ self.overlays.default ];


    # FIXME: remove once incus hits 7.0
    # see https://github.com/NixOS/nixpkgs/issues/490996 https://github.com/lxc/incus/issues/2956
    config.permittedInsecurePackages = [
      "minio-2025-10-15T17-29-55Z"
    ];
  };

  programs.nix-ld.enable = true;

  systemd.services.nix-daemon.serviceConfig.LimitNOFILE = lib.mkForce 40960;

  # Does not work with flakes
  programs.command-not-found.enable = false;

  programs.nh = {
    enable = true;
  };
}
