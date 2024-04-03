{ home-manager, nixpkgs, ... }: {
  imports = [
    home-manager.nixosModules.home-manager
    { nix.registry.nixpkgs.flake = nixpkgs; }
    ./hosts
    ./modules/system/core/terminal
    ./modules/system/core/nix
    ./modules/home/core/terminal
    ./modules/home/core/nix
  ];
}
