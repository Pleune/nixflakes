{
  combinators,
  lib,
  pkgs,
  ...
}:
let
  rawCombinators = {
    capture-host-home = import ./capture-host-home.nix {
      inherit combinators;
    };
    minimal-env = import ./minimal-env.nix {
      inherit combinators lib;
    };
    readonly-paths-from-var-resolved = import ./readonly-paths-from-var-resolved.nix {
      inherit combinators lib pkgs;
    };
    ro-bind-all-in-except = import ./ro-bind-all-in-except.nix {
      inherit combinators lib pkgs;
    };
    safe-path-from-var-resolved = import ./safe-path-from-var-resolved.nix {
      inherit combinators lib pkgs;
    };
  };
in
lib.mapAttrs (_: combinator: combinator.impl) rawCombinators
