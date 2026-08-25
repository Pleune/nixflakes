{
  lib,
  stdenvNoCC,
  fetchFromGitHub,
}:
let
  version = "0.4.2";
  rev = "39e6b998a2279c8fad4a2c6c64e26828c1d6023e";
in
stdenvNoCC.mkDerivation {
  pname = "pi-memory";
  inherit version;

  src = fetchFromGitHub {
    owner = "jayzeng";
    repo = "pi-memory";
    inherit rev;
    hash = "sha256-20hbBZ3loTvpun+CTUp2dRU77eKtSw4J2bS8rvsRGgM=";
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
