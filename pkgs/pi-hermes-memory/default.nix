{
  lib,
  buildNpmPackage,
  fetchFromGitHub,
  applyPatches,
}:
let
  version = "0.11.0";

  upstreamSrc = fetchFromGitHub {
    owner = "chandra447";
    repo = "pi-hermes-memory";
    rev = "v${version}";
    hash = "sha256-QvKgPKnOwTZtQpSl8DCDk4gROiYRqHPfGi+/YdOWnNg=";
  };

  src =
    if builtins.pathExists ./package-lock.patch then
      applyPatches {
        name = "pi-hermes-memory-${version}-source";
        src = upstreamSrc;
        patches = [ ./package-lock.patch ];
      }
    else
      upstreamSrc;
in
buildNpmPackage {
  pname = "pi-hermes-memory";
  inherit version src;

  npmDepsHash = "sha256-meG7aTYum/QZ5YuiKr9U09bQgKaoa3qV+8kKOB1Fwf8=";
  npmDepsFetcherVersion = 2;
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
