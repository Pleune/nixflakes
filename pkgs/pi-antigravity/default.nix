{
  lib,
  stdenvNoCC,
  fetchFromGitHub,
  fetchurl,
}:
let
  version = "0.7.3";

  undiciVersion = "8.10.0";
  undiciSrc = fetchurl {
    url = "https://registry.npmjs.org/undici/-/undici-${undiciVersion}.tgz";
    hash = "sha256-nXLFbBetKz1m8AbVOUU3TMDSvGjzIkOUlblyJp9N5rw=";
  };
in
stdenvNoCC.mkDerivation {
  pname = "pi-antigravity";
  inherit version;

  src = fetchFromGitHub {
    owner = "Rahularya01";
    repo = "pi-antigravity";
    rev = "v${version}";
    hash = "sha256-p0VTJxJM61HmDTg9nxd+zvaTzNOy8/Qu8ophMOjApCI=";
  };

  installPhase = ''
    runHook preInstall

    packageDir="$out/lib/node_modules/pi-antigravity"
    nodeModulesDir="$packageDir/node_modules"

    mkdir -p "$packageDir" "$nodeModulesDir"
    cp -r ./. "$packageDir/"

    mkdir -p "$nodeModulesDir/undici"
    tar -xzf ${undiciSrc} --strip-components=1 -C "$nodeModulesDir/undici"

    runHook postInstall
  '';

  passthru = {
    packageDir = "${placeholder "out"}/lib/node_modules/pi-antigravity";
  };

  meta = {
    description = "Pi provider for Google Antigravity / Cloud Code Assist models";
    homepage = "https://github.com/Rahularya01/pi-antigravity";
    license = lib.licenses.mit;
    platforms = lib.platforms.all;
  };
}
