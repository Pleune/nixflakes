{
  callPackage,
}:
let
  rpivMono = callPackage ../src.nix { };
  mkRpivPackage = callPackage ../mk-rpiv-package.nix { };
in
mkRpivPackage {
  pname = "rpiv-todo";
  inherit (rpivMono) version src;
  rpivDependencies = [
    "rpiv-config"
  ];
  description = "Pi extension that renders a live todo overlay surviving reload and conversation compaction";
  homepage = "https://github.com/juicesharp/rpiv-mono/tree/main/packages/rpiv-todo";
}