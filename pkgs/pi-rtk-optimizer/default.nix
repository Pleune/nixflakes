{
  lib,
  stdenvNoCC,
  fetchFromGitHub,
}:
let
  version = "0.9.0";
in
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "pi-rtk-optimizer";
  inherit version;

  src = fetchFromGitHub {
    owner = "MasuRii";
    repo = "pi-rtk-optimizer";
    rev = "v${version}";
    hash = "sha256-Cw0oLzVv674vpC3g5oteCNZSkHpfBN+IdnYDbkai4q4=";
  };

  dontBuild = true;

  installPhase = ''
    runHook preInstall

    packageDir="$out/lib/node_modules/pi-rtk-optimizer"
    mkdir -p "$packageDir/extensions/pi-rtk-optimizer"
    cp index.ts package.json README.md CHANGELOG.md LICENSE "$packageDir/"
    cp -r src config "$packageDir/"

    cat > "$packageDir/extensions/pi-rtk-optimizer/index.ts" <<'EOF'
    import extension from "../../index.ts";
    export default extension;
    EOF

    sed -i '/"pi": {/,/^[[:space:]]*},/ { /"extensions": \[/,/^[[:space:]]*\],/ s|"./index.ts"|"./extensions/pi-rtk-optimizer/index.ts"|; }' "$packageDir/package.json"

    runHook postInstall
  '';

  passthru = {
    packageDir = "${finalAttrs.finalPackage}/lib/node_modules/pi-rtk-optimizer";
    extensions = [
      "${finalAttrs.finalPackage}/lib/node_modules/pi-rtk-optimizer/extensions/pi-rtk-optimizer/index.ts"
    ];
  };

  meta = {
    description = "Pi extension for RTK command rewriting and tool output compaction";
    homepage = "https://github.com/MasuRii/pi-rtk-optimizer";
    license = lib.licenses.mit;
    platforms = lib.platforms.all;
  };
})
