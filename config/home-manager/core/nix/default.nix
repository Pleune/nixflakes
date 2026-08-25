{ pkgs, ... }:
{
  # especially important for system revision causing dangling user profile versions that never get cleaned up by root nix-collect-garbage
  nix.gc = {
    automatic = pkgs.lib.mkDefault true;
    # `nix.gc.frequency` was replaced by `nix.gc.dates` which expects a list.
    dates = [ "weekly" ];
  };
}
