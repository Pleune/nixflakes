{
  lib,
  stdenvNoCC,
  fetchFromGitHub,
}:
let
  rpivMono = import ../src.nix { inherit fetchFromGitHub; };
  mkRpivPackage = import ../mk-rpiv-package.nix {
    inherit lib stdenvNoCC;
  };
in
mkRpivPackage {
  pname = "rpiv-warp";
  inherit (rpivMono) version src;
  description = "Pi extension that sends native Warp terminal notifications for Pi lifecycle events";
  homepage = "https://github.com/juicesharp/rpiv-mono/tree/main/packages/rpiv-warp";
}
