{
  description = "Mitch's flake";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    deploy-rs.url = "github:serokell/deploy-rs";

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

    nixos-generators = {
      url = "github:nix-community/nixos-generators";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    private = {
      url = "git+ssh://git@git.pleunetowne.com:2223/mitchpleune/secrets.git";
      inputs.agenix.follows = "agenix";
      inputs.nixpkgs.follows = "nixpkgs";
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
          nixosConfigurations =
            let
              makeSystem =
                name:
                withSystem "x86_64-linux" (
                  ctx:
                  inputs.nixpkgs.lib.nixosSystem {
                    specialArgs = specialArgs ctx name;
                    modules = [
                      "${./.}/platforms/${name}.nix"
                      ./modules
                    ];
                  }
                );
            in
            {
              surface = makeSystem "surface";
              wsl = makeSystem "wsl";
              lxc = makeSystem "lxc";

              # homelab
              nas = makeSystem "nas";
              git = makeSystem "git";
              git-runner1 = makeSystem "git-runner1";
              immich = makeSystem "immich";
              nextcloud = makeSystem "nextcloud";
            };

          templates.default = {
            path = ./.;
            description = "The default template for Mitch's nixflakes.";
          };

          formatter.x86_64-linux = inputs.nixpkgs.legacyPackages.x86_64-linux.nixfmt;

          deploy.nodes =
            let
              homedeploy = name: extra: {
                hostname = "${name}.home.pleunetowne.com";
                profiles.system = {
                  sshUser = "root";
                  path = inputs.deploy-rs.lib.x86_64-linux.activate.nixos self.nixosConfigurations.${name};
                } // extra;
              };
            in
            {
              nas = homedeploy "nas" {};
              git = homedeploy "git" {};
              git-runner1 = homedeploy "git-runner1" {};
              immich = homedeploy "immich" {};
              nextcloud = homedeploy "nextcloud" {
                # cannot downgrade nextcloud!
                autoRollback = false;
                magicRollback = false;
              };
            };
          checks = builtins.mapAttrs (
            system: deployLib: deployLib.deployChecks self.deploy
          ) inputs.deploy-rs.lib;
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

            devShells.default = pkgs.mkShell {
              buildInputs = [ pkgs.deploy-rs ];
            };
          };
      }
    );
}
