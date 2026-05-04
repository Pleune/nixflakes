{
  lib,
  stdenvNoCC,
  fetchFromGitHub,
}:
let
  version = "0.2.6";
in
stdenvNoCC.mkDerivation {
  pname = "pi-quotas";
  inherit version;

  src = fetchFromGitHub {
    owner = "latentminds-ai";
    repo = "pi-quotas";
    rev = "v${version}";
    hash = "sha256-VT0z6CM659QfwofTET5ZnL/n2xWP5rF77t8s13n8AUI=";
  };

  installPhase = ''
    runHook preInstall

    # pi-agent.wrap probes lib/node_modules/pi-quotas first, but runtime imports use the scoped name.
    packageDir="$out/lib/node_modules/pi-quotas"
    scopedDir="$out/lib/node_modules/@latentminds"
    mkdir -p "$packageDir" "$scopedDir"
    cp -r ./. "$packageDir/"
    ln -s ../pi-quotas "$scopedDir/pi-quotas"

    runHook postInstall
  '';

  passthru = {
    packageDir = "${placeholder "out"}/lib/node_modules/@latentminds/pi-quotas";
  };

  meta = {
    description = "Pi extension package for monitoring AI provider quotas and warnings";
    homepage = "https://github.com/latentminds-ai/pi-quotas";
    license = lib.licenses.mit;
    platforms = lib.platforms.all;
  };
}
