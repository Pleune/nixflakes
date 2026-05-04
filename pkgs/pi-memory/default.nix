{
  lib,
  stdenvNoCC,
  fetchFromGitHub,
}:
let
  version = "0.3.9";
  rev = "dc144f6a5583499e17cf561105864bf28583764c";
in
stdenvNoCC.mkDerivation {
  pname = "pi-memory";
  inherit version;

  src = fetchFromGitHub {
    owner = "jayzeng";
    repo = "pi-memory";
    inherit rev;
    hash = "sha256-xxlTEEl7PPlKzG2pin+5LBgtHSqjtotyfOBJ9RDgi9A=";
  };

  installPhase = ''
    runHook preInstall

    packageDir="$out/lib/node_modules/pi-memory"
    mkdir -p "$packageDir"
    cp -r ./. "$packageDir/"

    runHook postInstall
  '';

  passthru = {
    packageDir = "${placeholder "out"}/lib/node_modules/pi-memory";
  };

  meta = {
    description = "Persistent memory for Pi that learns corrections, preferences, and project patterns";
    homepage = "https://github.com/jayzeng/pi-memory";
    license = lib.licenses.mit;
    platforms = lib.platforms.all;
  };
}
