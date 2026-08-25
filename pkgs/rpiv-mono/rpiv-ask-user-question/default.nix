{
  callPackage,
}:
let
  rpivMono = callPackage ../src.nix { };
  mkRpivPackage = callPackage ../mk-rpiv-package.nix { };
in
mkRpivPackage {
  pname = "rpiv-ask-user-question";
  inherit (rpivMono) version src;
  description = "Pi extension that shows a structured ask-user questionnaire instead of guessing";
  homepage = "https://github.com/juicesharp/rpiv-mono/tree/main/packages/rpiv-ask-user-question";
}
