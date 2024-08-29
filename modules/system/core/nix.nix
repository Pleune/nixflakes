{
  system,
  pkgs,
  nix-ld-rs,
  lib,
  inputs,
  ...
}:
{
  system = {
    extraSystemBuilderCmds = ''
      ln -sv ${pkgs.path} $out/nixpkgs
    '';
    stateVersion = "23.11";
  };

  # put all inputs on nix_path
  environment.etc = lib.mapAttrs' (name: flake: {
    name = "nix/inputs/${name}";
    value.source = flake.outPath;
  }) inputs;
  nix.nixPath = [ "/etc/nix/inputs" ];

  # put all inputs in flake registry
  nix.registry = lib.mapAttrs (n: flake: { inherit flake; }) inputs;

  nix = {
    package = pkgs.nixVersions.latest;
    #nixPath = [ "nixpkgs=/run/current-system/nixpkgs" ];
    #registry.nixpkgs.flake = nixpkgs;

    settings = {
      experimental-features = [
        "nix-command"
        "flakes"
      ];
      auto-optimise-store = true;
    };

    gc = {
      automatic = true;
      dates = "weekly";
      options = "--delete-older-than 30d";
    };
  };

  nixpkgs = {
    config.allowUnfree = true;
    hostPlatform = system;
  };

  programs.nix-ld = {
    enable = true;
    package = nix-ld-rs.packages."${pkgs.system}".nix-ld-rs;
  };

  systemd.services.nix-daemon.serviceConfig.LimitNOFILE = lib.mkForce 40960;

  # Does not work with flakes
  programs.command-not-found.enable = false;
}
