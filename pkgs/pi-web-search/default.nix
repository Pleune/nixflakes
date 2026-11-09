{
  lib,
  stdenvNoCC,
  fetchFromGitHub,
}:
let
  version = "1.7.0";
  rev = "cc47d6f8d5f340fb5d77214dab20380c37e280f4";
in
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "pi-web-search";
  inherit version;

  src = fetchFromGitHub {
    owner = "ttttmr";
    repo = "pi-web-search";
    inherit rev;
    hash = "sha256-l0sEmBifp/EdBuDBL1iVeLf4UbOS5W3VU0VFsEU8ocs=";
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
