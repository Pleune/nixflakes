{
  lib,
  stdenvNoCC,
  fetchFromGitHub,
}:
let
  version = "1.0.12";
in
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "pi-caveman";
  inherit version;

  src = fetchFromGitHub {
    owner = "jonjonrankin";
    repo = "pi-caveman";
    rev = "v${version}";
    hash = "sha256-XLX50aqar9vOt7XgSnBLk7BUKWw8U2ZLoC+M1pTy54A=";
  };

  dontBuild = true;

  installPhase = ''
    runHook preInstall

    packageDir="$out/lib/node_modules/pi-caveman"
    mkdir -p "$packageDir/extensions/pi-caveman"
    cp package.json README.md LICENSE "$packageDir/"
    cp -r extensions "$packageDir/"

    cat > "$packageDir/extensions/pi-caveman/index.ts" <<'EOF'
    import extension from "../../extensions/caveman.ts";
    export default extension;
    EOF

    sed -i '/"pi": {/,/^[[:space:]]*},/ { /"extensions": \[/,/^[[:space:]]*\],/ s|"./extensions/caveman.ts"|"./extensions/pi-caveman/index.ts"|; }' "$packageDir/package.json"

    runHook postInstall
  '';

  passthru = {
    packageDir = "${finalAttrs.finalPackage}/lib/node_modules/pi-caveman";
    extensions = [
      "${finalAttrs.finalPackage}/lib/node_modules/pi-caveman/extensions/pi-caveman/index.ts"
    ];
  };

  meta = {
    description = "Caveman mode extension for terse, token-efficient Pi responses";
    homepage = "https://github.com/jonjonrankin/pi-caveman";
    license = lib.licenses.mit;
    platforms = lib.platforms.all;
  };
})
