{
  lib,
  stdenvNoCC,
  fetchFromGitHub,
  fetchurl,
  makeWrapper,
  nodejs,
}:
let
  version = "0.56.0";

  src = fetchFromGitHub {
    owner = "nicobailon";
    repo = "pi-subagents";
    rev = "eb7820d4479530b497a40a2e1a3572d2b03621e5";
    hash = "sha256-Dde5ctGHoV9Rnn3Blcy/7utF8FWOm37YvFZvpeVlPKk=";
  };

  acornVersion = "8.18.0";
  acornSrc = fetchurl {
    url = "https://registry.npmjs.org/acorn/-/acorn-${acornVersion}.tgz";
    hash = "sha256-CtTA8o+bxbtvPrh5tP04Jl3vbX4eXWH5b3juaop76Uo=";
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

  yamlVersion = "2.8.3";
  yamlSrc = fetchurl {
    url = "https://registry.npmjs.org/yaml/-/yaml-${yamlVersion}.tgz";
    hash = "sha256-lTmAXXRH3vK+1cW0rKzCgzYsXoCrxdk0crLzXwy/ha0=";
  };
in
stdenvNoCC.mkDerivation (finalAttrs: {
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

    mkdir -p "$nodeModulesDir/acorn"
    tar -xzf ${acornSrc} \
      --strip-components=1 \
      -C "$nodeModulesDir/acorn"

    mkdir -p "$nodeModulesDir/jiti"
    tar -xzf ${jitiSrc} \
      --strip-components=1 \
      -C "$nodeModulesDir/jiti"

    mkdir -p "$nodeModulesDir/typebox"
    tar -xzf ${typeboxSrc} \
      --strip-components=1 \
      -C "$nodeModulesDir/typebox"

    mkdir -p "$nodeModulesDir/yaml"
    tar -xzf ${yamlSrc} \
      --strip-components=1 \
      -C "$nodeModulesDir/yaml"

    makeWrapper ${nodejs}/bin/node "$out/bin/pi-subagents" \
      --add-flags "$packageDir/install.mjs" \
      --set-default NODE_PATH "$nodeModulesDir"

    runHook postInstall
  '';

  passthru = {
    packageDir = "${finalAttrs.finalPackage}/lib/node_modules/pi-subagents";
    extensions = [ "${finalAttrs.finalPackage}/lib/node_modules/pi-subagents/index.ts" ];
    skills = [ "${finalAttrs.finalPackage}/lib/node_modules/pi-subagents/skills" ];
    prompts = [ "${finalAttrs.finalPackage}/lib/node_modules/pi-subagents/prompts" ];
  };

  meta = {
    description = "Pi extension for delegating tasks to subagents with chains, parallel execution, and TUI clarification";
    homepage = "https://github.com/nicobailon/pi-subagents";
    license = lib.licenses.mit;
    mainProgram = "pi-subagents";
    platforms = lib.platforms.all;
  };
})