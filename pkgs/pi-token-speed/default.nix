{
  lib,
  stdenvNoCC,
  fetchFromGitHub,
}:
let
  version = "0.12.0";
  rev = "46a3dd432d5b9c7493f69ecd464cc3beeef15178";
in
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "pi-token-speed";
  inherit version;

  src = fetchFromGitHub {
    owner = "gsanhueza";
    repo = "pi-token-speed";
    inherit rev;
    hash = "sha256-P6u5Og9SkEY6UQdx8IsV4xl4gBECUXHeofi6FxGDm/Q=";
  };

  installPhase = ''
    runHook preInstall

    packageDir="$out/lib/node_modules/pi-token-speed"
    mkdir -p "$packageDir"
    cp -r ./. "$packageDir/"

    runHook postInstall
  '';

  passthru = {
    packageDir = "${finalAttrs.finalPackage}/lib/node_modules/pi-token-speed";
    extensions = [ "${finalAttrs.finalPackage}/lib/node_modules/pi-token-speed/src/index.ts" ];
  };

  meta = {
    description = "Pi extension for measuring tokens-per-second streaming performance";
    homepage = "https://github.com/gsanhueza/pi-token-speed";
    license = lib.licenses.mit;
    platforms = lib.platforms.all;
  };
})
