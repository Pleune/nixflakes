{
  lib,
  stdenvNoCC,
  fetchFromGitHub,
}:
let
  version = "1.2.0";
in
stdenvNoCC.mkDerivation {
  pname = "pi-ask";
  inherit version;

  src = fetchFromGitHub {
    owner = "eko24ive";
    repo = "pi-ask";
    rev = "v${version}";
    hash = "sha256-lHAJMmtlnZyHU+QYUOyAiwnksm+DBu1FPqXhhr9qPLo=";
  };

  installPhase = ''
    runHook preInstall

    # pi-agent.wrap probes lib/node_modules/pi-ask first, but runtime imports use the scoped name.
    packageDir="$out/lib/node_modules/pi-ask"
    scopedDir="$out/lib/node_modules/@eko24ive"
    mkdir -p "$packageDir" "$scopedDir"
    cp -r ./. "$packageDir/"
    ln -s ../pi-ask "$scopedDir/pi-ask"

    runHook postInstall
  '';

  passthru = {
    packageDir = "${placeholder "out"}/lib/node_modules/@eko24ive/pi-ask";
  };

  meta = {
    description = "Pi package that adds an interactive ask_user clarification tool";
    homepage = "https://github.com/eko24ive/pi-ask";
    license = lib.licenses.mit;
    platforms = lib.platforms.all;
  };
}
