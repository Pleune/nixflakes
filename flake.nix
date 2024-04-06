{
  description = "Mitch's flake";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    NixOS-WSL = {
      url = "github:nix-community/NixOS-WSL";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, ... }@attrs:
    let
      supportedSystems = [ "x86_64-linux" ];
      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;
      nixpkgsFor = forAllSystems (system: import nixpkgs { inherit system; });
    in
    {

      nixosConfigurations = {

        surface =
          let system = "x86_64-linux";
          in nixpkgs.lib.nixosSystem {
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
              ./modules/home/core
              ./modules/home/applications/vscode
            ];
          };

        work-wsl =
          let system = "x86_64-linux";
          in nixpkgs.lib.nixosSystem {
            inherit system;
            specialArgs = {
              username = "mitch";
              hostName = "work-wsl";
              userFullName = "Mitchell Pleune";
              userEmail = "mitchell.pleune@magna.com";
              inherit system;
            } // attrs;
            modules = [
              {
                services.openssh = {
                  enable = true;
                  settings.PasswordAuthentication = true;
                };
              }
              ./platforms/wsl
              ./modules/system/core
              ./modules/home/core
              ./modules/system/services/gitea
            ];
          };

      };

      devShells = forAllSystems (system:
        let pkgs = nixpkgsFor.${system};
        in {
          default =
            pkgs.mkShell { buildInputs = with pkgs; [ nixfmt statix ]; };
        });

      templates.default = {
        path = ./.;
        description = "The default template for Mitch's nixflakes.";
      };

      formatter.x86_64-linux = nixpkgs.legacyPackages.x86_64-linux.nixfmt;
    };
}
