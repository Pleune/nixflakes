{ jail-nix, pkgs }:
{
  extend = jail-nix.lib.extend {
    inherit pkgs;
    additionalCombinators = combinators: import ./combinators.nix {
      inherit combinators pkgs;
      lib = pkgs.lib;
    };
  };
}
