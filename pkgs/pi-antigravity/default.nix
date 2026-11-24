{
  lib,
  stdenvNoCC,
  fetchFromGitHub,
  fetchurl,
}:
let
  version = "0.13.0";

  undiciVersion = "8.12.3";
  undiciSrc = fetchurl {
    url = "https://registry.npmjs.org/undici/-/undici-${undiciVersion}.tgz";
    hash = "sha256-4D+i7TR1J8kVAmwEgQ07m8+Yk6IXazFKpMKclFYS0Yw=";
  };
in
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "pi-antigravity";
  inherit version;

  src = fetchFromGitHub {
    owner = "Rahularya01";
    repo = "pi-antigravity";
    rev = "v${version}";
    hash = "sha256-cde2GYdAZ6FvIWI0Zf1PI94tao1fwsic9fIegnRn8hU=";
  };

  installPhase = ''
        runHook preInstall

        packageDir="$out/lib/node_modules/pi-antigravity"
        nodeModulesDir="$packageDir/node_modules"

        mkdir -p "$packageDir" "$nodeModulesDir"
        cp -r ./. "$packageDir/"

        mkdir -p "$packageDir/extensions/pi-antigravity"
        cat > "$packageDir/extensions/pi-antigravity/index.ts" <<'EOF'
    import extension from "../../src/index.ts";
    export default extension;
    EOF
        sed -i '/"pi": {/,/^[[:space:]]*},/ { /"extensions": \[/,/^[[:space:]]*\],/ s|"./src/index.ts"|"./extensions/pi-antigravity/index.ts"|; }' "$packageDir/package.json"

        mkdir -p "$nodeModulesDir/undici"
        tar -xzf ${undiciSrc} --strip-components=1 -C "$nodeModulesDir/undici"

        runHook postInstall
  '';

  passthru = {
    packageDir = "${finalAttrs.finalPackage}/lib/node_modules/pi-antigravity";
    extensions = [
      "${finalAttrs.finalPackage}/lib/node_modules/pi-antigravity/extensions/pi-antigravity/index.ts"
    ];
  };

  meta = {
    description = "Pi provider for Google Antigravity / Cloud Code Assist models";
    homepage = "https://github.com/Rahularya01/pi-antigravity";
    license = lib.licenses.mit;
    platforms = lib.platforms.all;
  };
})
