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
  pname = "rpiv-todo";
  inherit (rpivMono) version src;
  description = "Pi extension that renders a live todo overlay surviving reload and conversation compaction";
  homepage = "https://github.com/juicesharp/rpiv-mono/tree/main/packages/rpiv-todo";
}
