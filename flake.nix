{
  description = "Mitch's flake";

  nixConfig = {
    extra-substituters = [
      #"https://nix.pleunetowne.com"
      "https://nix-community.cachix.org"
      "https://cache.nixos-cuda.org"
      "https://numtide.cachix.org"
    ];
    extra-trusted-public-keys = [
      "git-runner1:uBsNvsIl85z2ApqcH88hIhc4F0uGl5vFmt5ohr3NZDA="
      "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
      "cache.nixos-cuda.org:74DUi4Ye579gUqzH4ziL9IyiJBlDpMRn9MBN8oNan9M="
      "numtide.cachix.org-1:2ps1kLBUWjxIneOy1Ik6cQjb41X0iXVXeHigGmycPPE="
    ];
  };

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
    };

    jail-nix = {
      url = "sourcehut:~alexdavid/jail.nix";
    };

    nixvim = {
      url = "github:nix-community/nixvim";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.flake-parts.follows = "flake-parts";
    };

    pi = {
      url = "github:lukasl-dev/pi.nix";
    };

    # Hermes Agent (Nous Research).  Consumed by platforms/llm.nix through its NixOS module
    # (services.hermes-agent), which is where Hermes is hosted.
    #
    # Forked rather than followed, because two Nix fixes it needs are still open PRs upstream:
    #  * #152542 -- nix/pm-packages.nix version-gates the patchelf PR672 backport.  On main the
    #    backport applies unconditionally and its patch only fits patchelf 0.19.x source; this repo's
    #    nixpkgs is on 0.15.2 (the 0.19 bump was reverted in NixOS/nixpkgs 61a15beb37), so every pm
    #    tool package failed with "4 out of 6 hunks FAILED".  With the gate, 0.15.2 is used as-is and
    #    nixpkgs can be followed normally.
    #  * #141834 -- uv's workspace metadata is read from the unfiltered repo root at eval time.  On
    #    main `loadWorkspace { workspaceRoot = pythonSrc; }` reads inside the filtered, derived
    #    `hermes-python-source` path, which is Import From Derivation: it forces that path to be
    #    realized just to evaluate the package.  CI runs `nix flake check --accept-flake-config
    #    --no-build`, which forbids realizing anything, so the whole pipeline died with
    #    "error: path '/nix/store/...-hermes-python-source' is not valid".
    #
    # Branch `nix-flake-fixes` is main plus both PRs, so no workaround is needed on our side.  Pin a
    # rev rather than a moving branch here once the fork's own CI has confirmed the branch.
    #
    # Switch back to `github:NousResearch/hermes-agent` once both PRs land in main.
    hermes-agent = {
      url = "github:Pleune/hermes-agent/nix-flake-fixes";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.home-manager.follows = "home-manager";
    };

    # Hermes WebUI (github:nesquena/hermes-webui).  Not in nixpkgs; it ships its own package and
    # NixOS module (services.hermes-webui), consumed by platforms/ai.nix.
    #
    # Follows nixpkgs so the WebUI package and the Hermes agent venv it runs the agent with are
    # built from the same package set.
    hermes-webui = {
      url = "github:nesquena/hermes-webui";
      inputs.nixpkgs.follows = "nixpkgs";
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
          overlays.default = import ./overlay.nix { inherit (inputs) jail-nix; };

          nixosConfigurations =
            let
              makeSystem =
                system: name: extraArgs:
                withSystem system (
                  ctx:
                  inputs.nixpkgs.lib.nixosSystem {
                    specialArgs = specialArgs ctx name // extraArgs;
                    modules = [
                      ./modules/nixos
                      ./config/nixos
                      (./platforms + "/${name}.nix")
                    ];
                  }
                );
              mk = name: makeSystem "x86_64-linux" name { };

              # Snapshot of this flake's own source, kept in the ai system's roots.  deploy-ai
              # diffs a candidate tree against it, which is how "what is deployed" is answerable
              # without a git repository on the host.  Nix copies the *tracked* files here, so
              # `.git`, untracked scratch (`state.json`, `.ralph/`) and gitignored paths are already
              # out; the filter only catches tracked names we never want shipped.
              #
              # Note the filter's second argument is the file *type* (`"regular"`, `"directory"`),
              # not the base name — match on `baseNameOf path` if you ever need names.
              nixflakesSource = builtins.path {
                path = ./.;
                name = "nixflakes-source";
                filter = path: _type:
                  ! builtins.elem (baseNameOf path) [ ".direnv" "result" "state.json" "secrets" ];
              };

              # The Hermes agent's execution host.  Its disk image is never installed by ai: the
              # guest is seeded with the seed image below and rebuilt from inside itself.
              buildvm = makeSystem "x86_64-linux" "buildvm" { };

              # Seed image for the guest disk.  Standalone on purpose: no host modules, no secrets
              # input, and nothing of it needs to survive in ai's store after first boot.
              buildvmBootstrap = inputs.nixpkgs.lib.nixosSystem {
                system = "x86_64-linux";
                modules = [ ./platforms/buildvm-bootstrap.nix ];
              };
            in
            {
              # live-iso = mk "live";

              lxc = mk "lxc";
              surface = mk "surface";
              wsl = mk "wsl";
              mitchpc = mk "mitchpc";

              # homelab
              # ai reaches the seed image through `self` (platforms/buildvm.nix reads
              # `self.nixosConfigurations.buildvmBootstrap`), so nothing about the guest is threaded in
              # here beyond what only the flake can supply.
              ai = makeSystem "x86_64-linux" "ai" {
                deployedSource = nixflakesSource;
                deployedCommit = self.rev or self.dirtyRev or "";
              };
              buildvm = buildvm;
              buildvmBootstrap = buildvmBootstrap;
              git = mk "git";
              git-runner1 = mk "git-runner1";
              immich = mk "immich";
              jellyfin = mk "jellyfin";
              jump = mk "jump";
              llm = mk "llm";
              nas = mk "nas";
              nextcloud = mk "nextcloud";
              notes = mk "notes";
              paperless = mk "paperless";
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
                mitchpi = inputs.pi.lib.mkCodingAgent {
                  inherit pkgs;
                  modules = [
                    (import ./config/pi-coding-agent/profile.nix {
                      inherit pkgs;
                      lib = pkgs.lib;
                    })
                  ];
                };
              in
              {
                mitchvim = inputs'.nixvim.legacyPackages.makeNixvimWithModule {
                  inherit pkgs;
                  module = import ./config/nixvim/options.nix { inherit pkgs; };
                };

                mitchpi = mitchpi.package;

                # `nix shell .#hermes-agent` (upstream's default output, CLI included) without
                # touching a generation.  The inputs' packages are not merged into pkgs here, and
                # the overlay would leak a python-heavy package into every package set.
                hermes-agent = inputs.hermes-agent.packages.${system}.default;

                # The only way the agent can activate ai; see modules/nixos/deploy-ai.
                deploy-ai = pkgs.deploy-ai;
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

            checks =
              deploy-rs.lib.${system}.deployChecks self.deploy
              # Not callPackage: that would add `override`/`overrideDerivation` keys, which are
              # functions and so fail the `attrsOf package` type of `checks`.
              // (import ./pkgs/strata/checks {
                inherit pkgs;
                inherit (pkgs)
                  lib
                  stdenv
                  runCommand
                  testers
                  curl
                  ;
                strataModule = import ./modules/nixos/strata;
                strataPkg = pkgs.strata;
              });

            formatter = inputs'.nixpkgs.legacyPackages.nixfmt;
          };
      }
    );
}
