{ hostName, ... }:
{
  imports = [
    ./nix
    ./terminal
    ./user
    ./trusted-substituters
  ];
  networking.hostName = "${hostName}";
}
