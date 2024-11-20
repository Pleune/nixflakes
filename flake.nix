{
  description = "Mitch's flake";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixpkgs-stable.url = "github:nixos/nixpkgs/nixos-24.05";

    flake-utils.url = "github:numtide/flake-utils";
    flake-parts.url = "github:hercules-ci/flake-parts";

    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    NixOS-WSL = {
      url = "github:nix-community/NixOS-WSL";
      inputs.nixpkgs.follows = "nixpkgs-stable";
      inputs.flake-utils.follows = "flake-utils";
    };

    # needed for microsoft surface configuration
    nixos-hardware = {
      url = "github:NixOS/nixos-hardware/master";
    };

    lanzaboote = {
      url = "github:nix-community/lanzaboote/v0.3.0";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.flake-utils.follows = "flake-utils";
    };

    agenix = {
      url = "github:ryantm/agenix";
      inputs.nixpkgs.follows = "nixpkgs-stable";
    };

    nixvim = {
      url = "github:nix-community/nixvim";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.flake-parts.follows = "flake-parts";
      inputs.home-manager.follows = "home-manager";
    };

    nixos-generators = {
      url = "github:nix-community/nixos-generators";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    private = {
      url = "git+ssh://git@git.pleunetowne.com:2223/mitchpleune/secrets.git";
      inputs.agenix.follows = "agenix";
      inputs.nixpkgs.follows = "nixpkgs-stable";
    };
  };

  outputs =
    inputs@{ self, flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit self inputs; } (
      { withSystem, ... }:
      let
        sysdef = {
          username = "mitch";
          userFullName = "Mitchell Pleune";
          userEmail = "mitchpleune@gmail.com";
        };
        specialArgs =
          ctx: hostName:
          {
            inherit (ctx) inputs' self' system;
            packages = ctx.config.packages;
            root = ./.;
            inherit inputs sysdef;
            hostName = hostName;
          }
          // inputs
          // sysdef;
      in
      {
        flake = {
          nixosConfigurations = {
            surface = withSystem "x86_64-linux" (
              ctx:
              inputs.nixpkgs.lib.nixosSystem {
                specialArgs = specialArgs ctx "surface";
                modules = [
                  ./platforms/surface.nix
                  ./modules
                ];
              }
            );

            wsl = withSystem "x86_64-linux" (
              ctx:
              inputs.nixpkgs.lib.nixosSystem {
                specialArgs = specialArgs ctx "wsl";
                modules = [
                  ./platforms/wsl.nix
                  ./modules
                ];
              }
            );

            lxc = withSystem "x86_64-linux" (
              ctx:
              inputs.nixpkgs.lib.nixosSystem {
                specialArgs = specialArgs ctx "lxc";
                modules = [
                  ./platforms/lxc.nix
                  ./modules
                ];
              }
            );

            nas = withSystem "x86_64-linux" (
              ctx:
              inputs.nixpkgs.lib.nixosSystem {
                # currently unstabled needed for rustic-rs
                specialArgs = (specialArgs ctx "nas");
                modules = [
                  ./platforms/nas.nix
                  ./modules
                ];
              }
            );
          };

          templates.default = {
            path = ./.;
            description = "The default template for Mitch's nixflakes.";
          };

          formatter.x86_64-linux = inputs.nixpkgs.legacyPackages.x86_64-linux.nixfmt;
        };

        systems = [ "x86_64-linux" ];
        perSystem =
          {
            system,
            pkgs,
            inputs',
            ...
          }@ctx:
          {
            packages = {
              mitchvim = inputs'.nixvim.legacyPackages.makeNixvim (
                import ./modules/home/core/terminal/nvim/options.nix { inherit pkgs; }
              );
              live-iso = inputs.nixos-generators.nixosGenerate {
                inherit system;
                specialArgs = specialArgs ctx "nixflakes-live";
                modules = [
                  "${inputs.nixpkgs}/nixos/modules/installer/cd-dvd/installation-cd-graphical-base.nix"
                  ./platforms/live.nix
                  ./modules
                ];
                format = "iso";
              };
            };
          };
      }
    );
}
