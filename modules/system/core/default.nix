{ hostName, ... }:
{
  imports = [
    ./nix.nix
    ./terminal.nix
    ./user.nix
    ./trusted-substituters.nix
  ];
  networking.hostName = "${hostName}";
}
