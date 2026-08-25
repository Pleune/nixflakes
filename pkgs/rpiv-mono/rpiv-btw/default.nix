{
  callPackage,
}:
let
  rpivMono = callPackage ../src.nix { };
  mkRpivPackage = callPackage ../mk-rpiv-package.nix { };
in
mkRpivPackage {
  pname = "rpiv-btw";
  inherit (rpivMono) version src;
  description = "Pi extension that adds the /btw side-question command without polluting the main conversation";
  homepage = "https://github.com/juicesharp/rpiv-mono/tree/main/packages/rpiv-btw";
}
