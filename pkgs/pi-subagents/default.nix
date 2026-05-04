{
  lib,
  stdenvNoCC,
  fetchFromGitHub,
  fetchurl,
  makeWrapper,
  nodejs,
}:
let
  version = "0.24.2";
  src = fetchFromGitHub {
    owner = "nicobailon";
    repo = "pi-subagents";
    rev = "635112deea068528d89694e58ca068ddc1fe4b2d";
    hash = "sha256-yBWgnZYw4OjSxKOmiQOltdM/jSbnHa/tdOBwUgNDkXU=";
  };

  jitiVersion = "2.7.0";
  jitiSrc = fetchurl {
    url = "https://registry.npmjs.org/jiti/-/jiti-${jitiVersion}.tgz";
    hash = "sha512-AC/7JofJvZGrrneWNaEnJeOLUx+JlGt7tNa0wZiRPT4MY1wmfKjt2+6O2p2uz2+skll8OZZmJMNqeke7kKbNgQ==";
  };

  typeboxVersion = "1.1.38";
  typeboxSrc = fetchurl {
    url = "https://registry.npmjs.org/typebox/-/typebox-${typeboxVersion}.tgz";
    hash = "sha512-pZ0aQPmMmXoUvSbeuWf/Hzsc+avNw/Zd6VeE8CFgkVGWyuHPJvqeJJDeJqLve+K70LvjYIoleGcoJHPT17cWoA==";
  };
in
stdenvNoCC.mkDerivation {
  pname = "pi-subagents";
  inherit version src;

  nativeBuildInputs = [
    makeWrapper
  ];

  installPhase = ''
    runHook preInstall

    packageDir="$out/lib/node_modules/pi-subagents"
    nodeModulesDir="$packageDir/node_modules"
    mkdir -p "$packageDir" "$nodeModulesDir" "$out/bin"
    cp -r . "$packageDir"

    mkdir -p "$nodeModulesDir/jiti"
    tar -xzf ${jitiSrc} --strip-components=1 -C "$nodeModulesDir/jiti"

    mkdir -p "$nodeModulesDir/typebox"
    tar -xzf ${typeboxSrc} --strip-components=1 -C "$nodeModulesDir/typebox"

    makeWrapper ${nodejs}/bin/node "$out/bin/pi-subagents" \
      --add-flags "$packageDir/install.mjs" \
      --set-default NODE_PATH "$out/lib/node_modules"

    runHook postInstall
  '';

  passthru = {
    packageDir = "${placeholder "out"}/lib/node_modules/pi-subagents";
  };

  meta = {
    description = "Pi extension for delegating tasks to subagents with chains, parallel execution, and TUI clarification";
    homepage = "https://github.com/nicobailon/pi-subagents";
    license = lib.licenses.mit;
    mainProgram = "pi-subagents";
    platforms = lib.platforms.all;
  };
}
