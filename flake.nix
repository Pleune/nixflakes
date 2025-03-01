{
  description = "Mitch's flake";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    nix = {
      url = "github:/nixos/nix?ref=2.16.1"; # using nix 2.16.1
      inputs.nixpkgs.follows = "nixpkgs";
    };

    deploy-rs = {
      url = "github:serokell/deploy-rs";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    flake-utils.url = "github:numtide/flake-utils";
    flake-parts.url = "github:hercules-ci/flake-parts";

    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    NixOS-WSL = {
      url = "github:nix-community/NixOS-WSL";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # needed for microsoft surface configuration
    nixos-hardware = {
      url = "github:NixOS/nixos-hardware/master";
    };

    lanzaboote = {
      url = "github:nix-community/lanzaboote/v0.4.2";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    agenix = {
      url = "github:ryantm/agenix";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.home-manager.follows = "home-manager";
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
      { withSystem, lib, ... }:
      let
        sysdef = {
          username = "mitch";
          userFullName = "Mitchell Pleune";
          userEmail = "mitchpleune@gmail.com";
        };
        specialArgs =
          ctx: hostName:
          {
            inherit (ctx) inputs' self';
            inherit inputs sysdef hostName;
            packages = ctx.config.packages;
            root = ./.;
          }
          // inputs
          // sysdef;

        deployPkgs =
          pkgs: system:
          import inputs.nixpkgs {
            system = "x86_64-linux";
            overlays = [
              inputs.deploy-rs.overlay # or deploy-rs.overlays.default
              (self: super: {
                deploy-rs = {
                  inherit (pkgs) deploy-rs;
                  lib = super.deploy-rs.lib;
                };
              })
            ];
          };
      in
      {
        flake = {
          overlays.default = import ./overlay.nix;

          nixosConfigurations =
            let
              makeSystem =
                name:
                withSystem "x86_64-linux" (
                  ctx:
                  inputs.nixpkgs.lib.nixosSystem {
                    specialArgs = specialArgs ctx name;
                    modules = [
                      ./modules
                      "${./.}/platforms/${name}.nix"
                    ];
                  }
                );
            in
            {
              lxc = makeSystem "lxc";
              surface = makeSystem "surface";
              wsl = makeSystem "wsl";

              # homelab
              git = makeSystem "git";
              git-runner1 = makeSystem "git-runner1";
              immich = makeSystem "immich";
              jump = makeSystem "jump";
              llm = makeSystem "llm";
              nas = makeSystem "nas";
              nextcloud = makeSystem "nextcloud";
              notes = makeSystem "notes";
            };

          deploy.nodes =
            let
              # TODO: dont hard-code system here
              pkgs = import inputs.nixpkgs {
                system = "x86_64-linux";
                overlays = [ self.overlays.default ];
              };
              homedeploy = name: extra: {
                hostname = "${name}.home.pleunetowne.com";
                profiles.system = {
                  sshUser = "root";
                  # TODO: dont hard-code system here
                  path =
                    (deployPkgs pkgs "x86_64-linux").deploy-rs.lib.activate.nixos
                      self.nixosConfigurations.${name};
                } // extra;
              };
            in
            {
              git = homedeploy "git" { };
              git-runner1 = homedeploy "git-runner1" { };
              immich = homedeploy "immich" { };
              jump = homedeploy "jump" { };
              llm = homedeploy "llm" { };
              nas = homedeploy "nas" { };
              nextcloud = homedeploy "nextcloud" {
                # cannot downgrade nextcloud!
                autoRollback = false;
                magicRollback = false;
              };
              notes = homedeploy "notes" { };
            };

          templates.default = {
            path = ./.;
            description = "The default template for Mitch's nixflakes.";
          };
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
            _module.args.pkgs = import self.inputs.nixpkgs {
              localSystem = {
                # gcc.arch = "alderlake";
                # gcc.tune = "alderlake";
                inherit system;
              };
              config = {
                cudaSupport = true;
                allowUnfree = true;
              };

              overlays = [ self.overlays.default ];
            };

            packages = {
              mitchvim = inputs'.nixvim.legacyPackages.makeNixvim (
                import ./modules/home/core/terminal/nvim/options.nix { inherit pkgs; }
              );
              incus-backup-rustic = pkgs.callPackage ./pkgs/incus-backup-rustic { };
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

            legacyPackages = pkgs;

            devShells.default = pkgs.mkShell {
              buildInputs = [
                pkgs.deploy-rs
                pkgs.agenix-cli
              ];
            };

            checks = (deployPkgs pkgs system).deploy-rs.lib.deployChecks self.deploy;
            formatter = inputs'.nixpkgs.legacyPackages.nixfmt-rfc-style;
          };
      }
    );
}
