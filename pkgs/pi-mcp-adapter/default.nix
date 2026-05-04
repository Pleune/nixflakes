{
  lib,
  buildNpmPackage,
  fetchFromGitHub,
  nodejs,
}:
let
  version = "2.5.3";
  src = fetchFromGitHub {
    owner = "nicobailon";
    repo = "pi-mcp-adapter";
    rev = "662595ef00ae5ba19c0e859e32f20a2a7595dbd3";
    hash = "sha256-NYry1MxmMlPRksocycyO7FxGTJuVg513BnwdKv72bWU=";
  };
in
buildNpmPackage {
  pname = "pi-mcp-adapter";
  inherit version src;

  npmDepsHash = "sha256-6keQh8iBF224CyZ09QfzWNQuEYYL+nybMPAwu81sp50=";

  dontNpmBuild = true;

  installPhase = ''
    runHook preInstall

    packageDir="$out/lib/node_modules/pi-mcp-adapter"
    mkdir -p "$packageDir" "$out/bin"
    cp -r . "$packageDir"

    makeWrapper ${nodejs}/bin/node "$out/bin/pi-mcp-adapter" \
      --add-flags "$packageDir/cli.js" \
      --set-default NODE_PATH "$out/lib/node_modules"

    runHook postInstall
  '';

  passthru = {
    packageDir = "${placeholder "out"}/lib/node_modules/pi-mcp-adapter";
  };

  meta = {
    description = "MCP (Model Context Protocol) adapter extension for Pi coding agent";
    homepage = "https://github.com/nicobailon/pi-mcp-adapter";
    license = lib.licenses.mit;
    mainProgram = "pi-mcp-adapter";
    platforms = lib.platforms.all;
    maintainers = [ ];
  };
}
