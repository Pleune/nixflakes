{
  lib,
  stdenvNoCC,
  fetchFromGitHub,
}:
let
  version = "0.4.2";
  rev = "842727466171c9e50209ed6fe53463a952e5a5f6";
in
stdenvNoCC.mkDerivation {
  pname = "pi-memory";
  inherit version;

  src = fetchFromGitHub {
    owner = "jayzeng";
    repo = "pi-memory";
    inherit rev;
    hash = "sha256-kkVK08sX9d7m1uT1XvG8Y0kplwmaDXf+rqS1LMmDgNw=";
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
