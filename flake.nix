{
  description = "Mitch's flake";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";

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

    private = {
      url = "git+ssh://gitea@git.pleunetowne.com:2223/mitchpleune/secrets.git";
      inputs.agenix.follows = "agenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      ...
    }@attrs:
    {
      nixosConfigurations = {
        surface =
          let
            system = "x86_64-linux";
          in
          nixpkgs.lib.nixosSystem {
            inherit system;
            specialArgs = {
              username = "mitch";
              userFullName = "Mitchell Pleune";
              userEmail = "mitchpleune@gmail.com";
              hostName = "surface";
            } // attrs;
            modules = [
              ./platforms/surface
              ./modules/system/core
              ./modules/system/lanzaboote
              ./modules/system/agenix
              ./modules/system/networkmanager/pleunenet # requires agenix
              ./modules/home/core
              ./modules/home/gpg
              ./modules/home/apps/vscode
              ./modules/home/apps/nvim
              ./modules/home/apps/misc
              ./modules/home/theme/gnome
              ./modules/home/syncthing
            ];
          };

        work-wsl =
          let
            system = "x86_64-linux";
          in
          nixpkgs.lib.nixosSystem {
            inherit system;
            specialArgs = {
              username = "mitch";
              hostName = "work-wsl";
              userFullName = "Mitchell Pleune";
              userEmail = "mitchell.pleune@magna.com";
              inherit system;
            } // attrs;
            modules = [
              ./platforms/wsl
              ./modules/system/core
              ./modules/home/core
              ./modules/system/services/gitea
              ./modules/home/apps/nvim
              ./modules/home/theme/gtk-wsl
              ./modules/system/ssl
            ];
          };
      };

      devShells = flake-utils.lib.eachDefaultSystem (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          default = pkgs.mkShell {
            buildInputs = with pkgs; [
              nixfmt
              statix
            ];
          };
        }
      );

      templates.default = {
        path = ./.;
        description = "The default template for Mitch's nixflakes.";
      };

      formatter.x86_64-linux = nixpkgs.legacyPackages.x86_64-linux.nixfmt;
    };
}
