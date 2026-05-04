{
  lib,
  stdenvNoCC,
  fetchurl,
  makeWrapper,
  nodejs,
}:
let
  version = "1.0.107";

  turndownSrc = fetchurl {
    url = "https://registry.npmjs.org/turndown/-/turndown-7.2.0.tgz";
    hash = "sha512-eCZGBN4nNNqM9Owkv9HAtWRYfLA4h909E/WGAWWBpmB275ehNhZyk87/Tpvjbp0jjNl9XwCsbe6bm6CqFsgD+A==";
  };

  turndownPluginGfmSrc = fetchurl {
    url = "https://registry.npmjs.org/turndown-plugin-gfm/-/turndown-plugin-gfm-1.0.2.tgz";
    hash = "sha512-vwz9tfvF7XN/jE0dGoBei3FXWuvll78ohzCZQuOb+ZjWrs3a0XhQVomJEb2Qh4VHTPNRO4GPZh0V7VRbiWwkRg==";
  };

  dominoSrc = fetchurl {
    url = "https://registry.npmjs.org/@mixmark-io/domino/-/domino-2.2.0.tgz";
    hash = "sha512-Y28PR25bHXUg88kCV7nivXrP2Nj2RueZ3/l/jdx6J9f8J4nsEGcgX0Qe6lt7Pa+J79+kPiJU3LguR6O/6zrLOw==";
  };
in
stdenvNoCC.mkDerivation {
  pname = "context-mode";
  inherit version;

  src = fetchurl {
    url = "https://registry.npmjs.org/context-mode/-/context-mode-${version}.tgz";
    hash = "sha512-UDFTMJpPAgh2cxn6PU6PswS8C21SAhCOaPwMvZbSqwdCHqaAHTEte83x+Yh5lS+szu/1f4F6xmwMzIkAFoGA8A==";
  };

  nativeBuildInputs = [ makeWrapper ];

  unpackPhase = ''
    runHook preUnpack
    tar -xzf "$src"
    runHook postUnpack
  '';

  installPhase = ''
    runHook preInstall

    nodeModulesDir="$out/lib/node_modules"
    packageDir="$nodeModulesDir/context-mode"
    mkdir -p "$packageDir" "$out/bin"
    cp -r package/. "$packageDir/"

    mkdir -p \
      "$nodeModulesDir/turndown" \
      "$nodeModulesDir/turndown-plugin-gfm" \
      "$nodeModulesDir/@mixmark-io/domino"

    tar -xzf ${turndownSrc} --strip-components=1 -C "$nodeModulesDir/turndown"
    tar -xzf ${turndownPluginGfmSrc} --strip-components=1 -C "$nodeModulesDir/turndown-plugin-gfm"
    tar -xzf ${dominoSrc} --strip-components=1 -C "$nodeModulesDir/@mixmark-io/domino"

    mkdir -p "$nodeModulesDir/turndown/node_modules/@mixmark-io"
    ln -s "$nodeModulesDir/@mixmark-io/domino" "$nodeModulesDir/turndown/node_modules/@mixmark-io/domino"

    makeWrapper ${nodejs}/bin/node "$out/bin/context-mode" \
      --add-flags "$packageDir/cli.bundle.mjs" \
      --set-default NODE_PATH "$nodeModulesDir"

    runHook postInstall
  '';

  passthru = {
    packageDir = "${placeholder "out"}/lib/node_modules/context-mode";
  };

  meta = {
    description = "MCP plugin that saves context window usage and integrates with Pi";
    homepage = "https://github.com/mksglu/context-mode";
    license = lib.licenses.elastic20;
    mainProgram = "context-mode";
    platforms = lib.platforms.all;
    maintainers = [ ];
  };
}
