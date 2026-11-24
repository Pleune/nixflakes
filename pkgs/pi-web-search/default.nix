{
  lib,
  stdenvNoCC,
  fetchFromGitHub,
}:
let
  version = "1.7.0";
  rev = "9442b123c9dc56fcc659cdd013c9e6da0374235e";
in
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "pi-web-search";
  inherit version;

  src = fetchFromGitHub {
    owner = "ttttmr";
    repo = "pi-web-search";
    inherit rev;
    hash = "sha256-PWKlEF8bn89VIvSdXkSr6uBT2d8J45SWcmCCOJc0scU=";
  };

  dontBuild = true;

  installPhase = ''
    runHook preInstall

    packageDir="$out/lib/node_modules/pi-web-search"
    mkdir -p "$packageDir/extensions/pi-web-search"
    cp package.json README.md "$packageDir/"
    cp -r src "$packageDir/"

    cat > "$packageDir/extensions/pi-web-search/index.ts" <<'EOF'
    import extension from "../../src/index.ts";
    export default extension;
    EOF

    sed -i '/"pi": {/,/^[[:space:]]*},/ { /"extensions": \[/,/^[[:space:]]*\],/ s|"./src/index.ts"|"./extensions/pi-web-search/index.ts"|; }' "$packageDir/package.json"

    runHook postInstall
  '';

  passthru = {
    packageDir = "${finalAttrs.finalPackage}/lib/node_modules/pi-web-search";
    extensions = [
      "${finalAttrs.finalPackage}/lib/node_modules/pi-web-search/extensions/pi-web-search/index.ts"
    ];
  };

  meta = {
    description = "Provider-native web search and URL context tools for Pi";
    homepage = "https://github.com/ttttmr/pi-web-search";
    license = lib.licenses.mit;
    platforms = lib.platforms.all;
  };
})
