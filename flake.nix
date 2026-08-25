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

    jail-nix = {
      url = "sourcehut:~alexdavid/jail.nix";
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
            inherit (ctx) inputs' self';
            inherit inputs sysdef hostName;
            packages = ctx.config.packages;
            root = ./.;
          }
          // inputs
          // sysdef;

        makePkgs =
          system: march: mtune:
          import inputs.nixpkgs {
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
                system: name:
                withSystem system (
                  ctx:
                  inputs.nixpkgs.lib.nixosSystem {
                    specialArgs = specialArgs ctx name;
                    modules = [
                      ./modules/nixos
                      ./config/nixos
                      (./platforms + "/${name}.nix")
                    ];
                  }
                );
            in
            {
              # live-iso = makeSystem "x86_64-linux" "live";

              lxc = makeSystem "x86_64-linux" "lxc";
              surface = makeSystem "x86_64-linux" "surface";
              wsl = makeSystem "x86_64-linux" "wsl";

              # homelab
              git = makeSystem "x86_64-linux" "git";
              git-runner1 = makeSystem "x86_64-linux" "git-runner1";
              immich = makeSystem "x86_64-linux" "immich";
              jellyfin = makeSystem "x86_64-linux" "jellyfin";
              jump = makeSystem "x86_64-linux" "jump";
              llm = makeSystem "x86_64-linux" "llm";
              nas = makeSystem "x86_64-linux" "nas";
              nextcloud = makeSystem "x86_64-linux" "nextcloud";
              notes = makeSystem "x86_64-linux" "notes";
              paperless = makeSystem "x86_64-linux" "paperless";
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
          }:
          {
            _module.args.pkgs = makePkgs system null null;

            packages =
              let
                jailLib = import ./lib/jail {
                  inherit pkgs;
                  jail-nix = inputs.jail-nix;
                };
                piAgentLib = import ./lib/pi-agent { lib = pkgs.lib; };
                mitchpiProfile = import ./config/pi-agent/profile.nix { inherit pkgs; };
                mitchpiInventory = piAgentLib.inventoryFromProfile {
                  inherit pkgs;
                  profile = mitchpiProfile;
                };
                jail = jailLib.extend;
              in
              {
                mitchvim = inputs'.nixvim.legacyPackages.makeNixvimWithModule {
                  inherit pkgs;
                  module = import ./config/nixvim/options.nix { inherit pkgs; };
                };

                # Sandboxed pi-agent with network access and write access to current directory only.
                # Wrap it once more so sub-processes launched from inside the jail resolve this flake's
                # mitchpi/pi executable first instead of an unrelated host-profile pi on PATH.
                mitchpi =
                  let
                    base = jail "pi" pkgs.pi-coding-agent (
                      piAgentLib.jailProfile {
                        inherit jail;
                        inventory = mitchpiInventory;
                      }
                    );
                  in
                  pkgs.symlinkJoin {
                    name = "mitchpi";
                    paths = [ base ];
                    nativeBuildInputs = [ pkgs.makeWrapper ];
                    postBuild = ''
                      rm "$out/bin/pi"
                      makeWrapper ${base}/bin/pi "$out/bin/pi" \
                        --prefix PATH : "$out/bin"
                      ln -s pi "$out/bin/mitchpi"
                    '';
                    meta = base.meta // {
                      mainProgram = "pi";
                    };
                  };
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

            checks = deploy-rs.lib.${system}.deployChecks self.deploy;
            formatter = inputs'.nixpkgs.legacyPackages.nixfmt;
          };
      }
    );
}
