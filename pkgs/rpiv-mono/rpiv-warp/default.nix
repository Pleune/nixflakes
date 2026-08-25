{
  callPackage,
}:
let
  rpivMono = callPackage ../src.nix { };
  mkRpivPackage = callPackage ../mk-rpiv-package.nix { };
in
mkRpivPackage {
  pname = "rpiv-warp";
  inherit (rpivMono) version src;
  description = "Pi extension that sends native Warp terminal notifications for Pi lifecycle events";
  homepage = "https://github.com/juicesharp/rpiv-mono/tree/main/packages/rpiv-warp";
}