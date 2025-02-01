{ self, ... }:
{
  # only import system,
  # home is imported from the system users config
  imports = [ ./system ];

  nixpkgs.overlays = [ (import "${self}/overlay.nix") ];
}
