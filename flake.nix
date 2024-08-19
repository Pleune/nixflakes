{
  description = "Mitch's flake";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    flake-parts.url = "github:hercules-ci/flake-parts";

    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    NixOS-WSL = {
      url = "github:nix-community/NixOS-WSL";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.flake-utils.follows = "flake-utils";
    };

    nix-ld-rs = {
      url = "github:nix-community/nix-ld-rs";
      inputs.nixpkgs.follows = "nixpkgs";
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
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nixvim = {
      url = "github:nix-community/nixvim";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.flake-parts.follows = "flake-parts";
      inputs.home-manager.follows = "home-manager";
    };

    private = {
      url = "git+ssh://gitea@git.pleunetowne.com:2223/mitchpleune/secrets.git";
      inputs.agenix.follows = "agenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    inputs@{ self, flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit self inputs; } (
      { withSystem, ... }:
      {
        flake = {
          nixosConfigurations =
            let
              specialArgs =
                ctx: hostName:
                {
                  hostName = hostName;
                  username = "mitch";
                  userFullName = "Mitchell Pleune";
                  userEmail = "mitchpleune@gmail.com";
                  inherit (ctx) inputs' self' system;
                  packages = ctx.config.packages;
                }
                // inputs;

            in
            {
              surface = withSystem "x86_64-linux" (
                ctx:
                inputs.nixpkgs.lib.nixosSystem {
                  specialArgs = specialArgs ctx "surface";
                  modules = [
                    ./platforms/surface
                    ./modules/system
                    ./modules/home/core
                    ./modules/home/gpg
                    ./modules/home/apps/vscode
                    ./modules/home/apps/misc
                    ./modules/home/theme/gnome
                    ./modules/home/syncthing
                  ];
                }
              );

              wsl = withSystem "x86_64-linux" (
                ctx:
                inputs.nixpkgs.lib.nixosSystem {
                  specialArgs = specialArgs ctx "wsl";
                  modules = [
                    ./platforms/wsl
                    ./modules/home/core
                    ./modules/home/theme/gtk-wsl
                    ./modules/system
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
          { pkgs, inputs', ... }:
          {
            packages = {
              mitchvim = pkgs.callPackage ./pkgs/mitchvim {
                makeNixvim = inputs'.nixvim.legacyPackages.makeNixvim;
              };
            };
          };
      }
    );
}
