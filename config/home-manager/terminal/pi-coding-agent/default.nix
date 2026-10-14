{
  pkgs,
  ...
}:
let
  profile = import ../../../pi-coding-agent/profile.nix {
    inherit pkgs;
    lib = pkgs.lib;
  };
in
{
  config = {
    programs.pi.coding-agent = {
      enable = true;
    }
    // profile.pi.coding-agent;
  };
}
