{ lib }:
let
  inventoryFromProfile = import ./inventory.nix { inherit lib; };
  jailProfile = import ./jail-profile.nix { inherit lib; };
in
{
  inherit inventoryFromProfile jailProfile;
  homeLinkSpecs = args: import ./home-link-specs.nix args;
}
