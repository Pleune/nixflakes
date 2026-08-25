{
  lib,
  stdenvNoCC,
  fetchFromGitHub,
}:
let
  version = "0.4.0";
in
stdenvNoCC.mkDerivation {
  pname = "pi-quotas";
  inherit version;

  src = fetchFromGitHub {
    owner = "latentminds-ai";
    repo = "pi-quotas";
    rev = "v${version}";
    hash = "sha256-FK60s7wj42MxrjYhE9IAlT5TkOdqr/ZHqS5uKpMDZwU=";
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
