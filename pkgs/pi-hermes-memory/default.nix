{
  lib,
  buildNpmPackage,
  fetchFromGitHub,
}:
let
  version = "0.7.4";
  src = fetchFromGitHub {
    owner = "chandra447";
    repo = "pi-hermes-memory";
    rev = "v${version}";
    hash = "sha256-eVM8Lb/RdSske21v5ICXOOzY8VCuImNzLFTBAtIJyPI=";
  };
in
buildNpmPackage {
  pname = "pi-hermes-memory";
  inherit version src;

  npmDepsHash = "sha256-mZFrPy94VeEo26nRjMfUamJhXPepAPmVq/Svyn0CmBM=";

  dontNpmBuild = true;

  installPhase = ''
    runHook preInstall

    packageDir="$out/lib/node_modules/pi-hermes-memory"
    mkdir -p "$packageDir"
    cp -r . "$packageDir"

    runHook postInstall
  '';

  passthru = {
    packageDir = "${placeholder "out"}/lib/node_modules/pi-hermes-memory";
  };

  meta = {
    description = "Persistent memory, session search, and secret scanning extension for Pi";
    homepage = "https://github.com/chandra447/pi-hermes-memory";
    license = lib.licenses.mit;
    platforms = lib.platforms.all;
  };
}
