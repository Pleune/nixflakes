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
  pname = "rpiv-btw";
  inherit (rpivMono) version src;
  description = "Pi extension that adds the /btw side-question command without polluting the main conversation";
  homepage = "https://github.com/juicesharp/rpiv-mono/tree/main/packages/rpiv-btw";
}
