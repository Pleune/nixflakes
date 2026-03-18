{ self, ... }:
{
  # espically important for system revision causing dangling user profile versions that never get cleaned up by root nix-collect-garbage
  nix.gc = {
    automatic = true;
    # `nix.gc.frequency` was replaced by `nix.gc.dates` which expects a list.
    dates = [ "weekly" ];
  };

  # TODO: only apply if not using nixos nixpkgs
  # when HM only, need to apply overlays through hm nixpkgs instantiation
  nixpkgs.overlays = [ (import "${self}/overlay.nix") ];
}
