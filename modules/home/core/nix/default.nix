{ ... }:
{
  # espically important for system revision causing dangling user profile versions that never get cleaned up by root nix-collect-garbage
  nix.gc = {
    automatic = true;
    frequency = "daily";
  };

  home.stateVersion = "24.05";
}
