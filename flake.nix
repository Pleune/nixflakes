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
      url = "github:nix-community/lanzaboote";
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
    };

    private = {
      url = "git+ssh://git@git.pleunetowne.com:2223/mitchpleune/secrets.git";
      inputs.agenix.follows = "agenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    inputs@{
      self,
      flake-parts,
      deploy-rs,
      ...
    }:
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

        makePkgs =
          system: march: mtune:
          import self.inputs.nixpkgs {
            localSystem = {
              inherit system;
            }
            // (
              if march != null then
                {
                  gcc.arch = march;
                }
              else
                { }
            )
            // (
              if mtune != null then
                {
                  gcc.tune = mtune;
                }
              else
                { }
            );

            config = {
              cudaSupport = true;
              allowUnfree = true;
            };

            overlays = [
              self.overlays.default
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
              live-iso = makeSystem "live";

              lxc = makeSystem "lxc";
              surface = makeSystem "surface";
              wsl = makeSystem "wsl";

              # homelab
              git = makeSystem "git";
              git-runner1 = makeSystem "git-runner1";
              immich = makeSystem "immich";
              jellyfin = makeSystem "jellyfin";
              jump = makeSystem "jump";
              llm = makeSystem "llm";
              nas = makeSystem "nas";
              nextcloud = makeSystem "nextcloud";
              notes = makeSystem "notes";
              paperless = makeSystem "paperless";
            };

          deploy.nodes =
            let
              homedeploy = name: extra: {
                hostname = "${name}.home.pleunetowne.com";
                profiles.system = {
                  sshUser = "root";
                  # TODO: dont hard-code system here
                  path = deploy-rs.lib.x86_64-linux.activate.nixos self.nixosConfigurations.${name};
                }
                // extra;
              };
            in
            {
              git = homedeploy "git" { };
              git-runner1 = homedeploy "git-runner1" { };
              immich = homedeploy "immich" { };
              jellyfin = homedeploy "jellyfin" { };
              jump = homedeploy "jump" { };
              llm = homedeploy "llm" { };
              nas = homedeploy "nas" { };
              nextcloud = homedeploy "nextcloud" {
                # cannot downgrade nextcloud!
                autoRollback = false;
                magicRollback = false;
              };
              notes = homedeploy "notes" { };
              paperless = homedeploy "paperless" { };
            };

          homeConfigurations."mitch@surface" =
            self.nixosConfigurations.surface.config.home-manager.users.mitch.home;

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
            _module.args.pkgs = makePkgs system null null;

            packages = {
              mitchvim = inputs'.nixvim.legacyPackages.makeNixvim (
                import ./modules/home/core/terminal/nvim/options.nix { inherit pkgs; }
              );
            };

            legacyPackages = pkgs // {
              alderlake = makePkgs system "alderlake" "alderlake"; # for nas systems
              skylake = makePkgs system "skylake" "skylake"; # for surface
            };

            devShells.default = pkgs.mkShell {
              buildInputs = [
                deploy-rs.packages."${system}".deploy-rs
                pkgs.agenix-cli
              ];
            };

            # for deploy-rs from pkgs
            # checks = (deployPkgs pkgs system).deploy-rs.lib.deployChecks self.deploy;

            formatter = inputs'.nixpkgs.legacyPackages.nixfmt;
          };
      }
    );
}
