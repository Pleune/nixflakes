{
  lib,
  pkgs,
  stdenv,
  runCommand,
  testers,
  curl,
  strataModule,
  strataPkg,
}:

# Everything that validates the strata packaging and the module, wired into flake.nix's `checks`.
# Names are `strata-` prefixed because `checks` is one flat attrset for the whole flake, and
# `vm`/`serve-smoke` alone would be ambiguous next to other packages' checks.
# strata-serve-smoke, strata-prefetch-*, strata-vm need the built bundle (strata-vm builds it but
# never the CUDA engine); strata-module-* checks evaluate against stub packages, so they need no build.
{
  strata-serve-smoke = import ./serve-smoke.nix {
    inherit stdenv strataPkg curl;
  };

  strata-prefetch-vision = import ./prefetch-vision.nix {
    inherit stdenv strataPkg;
  };

  strata-prefetch-gyro = import ./prefetch-gyro.nix {
    inherit stdenv strataPkg;
  };

  strata-module-vision = import ./module-vision.nix {
    inherit
      lib
      pkgs
      runCommand
      strataModule
      ;
  };

  strata-module-parallel = import ./module-parallel.nix {
    inherit
      lib
      pkgs
      runCommand
      strataModule
      ;
  };

  strata-module-extra-args = import ./module-extra-args.nix {
    inherit
      lib
      pkgs
      runCommand
      strataModule
      ;
  };

  strata-module-gyro = import ./module-gyro.nix {
    inherit
      lib
      pkgs
      runCommand
      strataModule
      ;
  };

  strata-module-hosts = import ./module-hosts.nix {
    inherit
      lib
      pkgs
      runCommand
      strataModule
      ;
  };

  strata-vm = import ./vm.nix {
    inherit testers strataModule strataPkg;
  };
}
