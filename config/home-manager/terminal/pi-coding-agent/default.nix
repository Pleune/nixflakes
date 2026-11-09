{
  pkgs,
  ...
}:
let
  profile = import ../../../pi-coding-agent/profile.nix {
    inherit pkgs;
    lib = pkgs.lib;
    persistCavemanConfig = true;
  };
in
{
  config = {
    home.packages = [ pkgs.agent-sandbox ];

    programs.pi.coding-agent = {
      enable = true;
    }
    // profile.pi.coding-agent;
  };
}
