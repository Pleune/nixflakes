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
  pname = "rpiv-ask-user-question";
  inherit (rpivMono) version src;
  description = "Pi extension that shows a structured ask-user questionnaire instead of guessing";
  homepage = "https://github.com/juicesharp/rpiv-mono/tree/main/packages/rpiv-ask-user-question";
}
