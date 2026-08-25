{
  lib,
  stdenvNoCC,
  fetchFromGitHub,
  fetchPnpmDeps,
  pnpmConfigHook,
  pnpm_10,
  nodejs,
}:
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "pi-token-burden";
  version = "0.6.5";

  src = fetchFromGitHub {
    owner = "Whamp";
    repo = "pi-token-burden";
    rev = "v${finalAttrs.version}";
    hash = "sha256-huH4RpCNWXsOInW/HLhK7daW5Lv6zdychVRrXJicJvQ=";
  };

  pnpmDeps = fetchPnpmDeps {
    inherit (finalAttrs) pname version src;
    pnpm = pnpm_10;
    fetcherVersion = 3;
    pnpmInstallFlags = [ "--prod" ];
    hash = "sha256-MUcQSMEE8Qb5naNOFtsqiuEEecPkXUycTzn3gIA7KYo=";
  };

  pnpmInstallFlags = [ "--prod" ];

  nativeBuildInputs = [
    nodejs
    pnpm_10
    pnpmConfigHook
  ];

  dontBuild = true;

  installPhase = ''
    runHook preInstall

    packageDir="$out/lib/node_modules/pi-token-burden"
    mkdir -p "$packageDir"
    cp -r . "$packageDir"

    runHook postInstall
  '';

  passthru = {
    packageDir = "${placeholder "out"}/lib/node_modules/pi-token-burden";
  };

  meta = {
    description = "Pi extension that shows a token-budget breakdown of the assembled system prompt";
    homepage = "https://github.com/Whamp/pi-token-burden";
    license = lib.licenses.mit;
    platforms = lib.platforms.all;
  };
})
