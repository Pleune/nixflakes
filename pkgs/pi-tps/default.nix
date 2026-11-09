{
  lib,
  stdenvNoCC,
  fetchFromGitHub,
}:
let
  version = "1.3.19";
  rev = "4addc256d71e08c2e074bc2d92d45d42369d5e3c";
in
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "pi-tps";
  inherit version;

  src = fetchFromGitHub {
    owner = "monotykamary";
    repo = "pi-tps";
    inherit rev;
    hash = "sha256-a9+YO1VO73azu4bHKG7tRtmf7Sz1pG0uvwWpMwyEd1w=";
  };

  installPhase = ''
    runHook preInstall

    packageDir="$out/lib/node_modules/pi-tps"
    mkdir -p "$packageDir/extensions/pi-tps"
    cp package.json README.md LICENSE "$packageDir/"
    sed -i '/"pi": {/,/^[[:space:]]*},/ { /"extensions": \[/,/^[[:space:]]*\],/ s|"./extensions"|"./extensions/pi-tps/index.ts"|; }' "$packageDir/package.json"
    cp extensions/pi-tps/index.ts "$packageDir/extensions/pi-tps/index.ts"

    runHook postInstall
  '';

  passthru = {
    packageDir = "${finalAttrs.finalPackage}/lib/node_modules/pi-tps";
    extensions = [ "${finalAttrs.finalPackage}/lib/node_modules/pi-tps/extensions/pi-tps/index.ts" ];
  };

  meta = {
    description = "Pi extension for tracking tokens-per-second, TTFT, stalls, and token cost";
    homepage = "https://github.com/monotykamary/pi-tps";
    license = lib.licenses.mit;
    platforms = lib.platforms.all;
  };
})
