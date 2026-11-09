{
  lib,
  stdenvNoCC,
  fetchFromGitHub,
  fetchurl,
}:
let
  version = "0.1.212";
  npmSha512 = "Bwjl4StlMNcE3JWe15iKLATwk5q8rgiNgR/isk5fCnOYfhtE8vsrtJPCqA5WGvsT2yJ9p/j3k4NUAkQER5qjjg==";
in
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "billion-context";
  inherit version;

  src = fetchFromGitHub {
    owner = "ranxianglei";
    repo = "billion-context";
    rev = "v${version}";
    hash = "sha256-a2MAaWAHlGGoji7dDE7mBcAgDdlHrFwqBkKsrFS9LkY=";
  };

  npmTarball = fetchurl {
    url = "https://registry.npmjs.org/billion-context/-/billion-context-${version}.tgz";
    hash = "sha512-${npmSha512}";
  };

  dontUnpack = true;

  installPhase = ''
        runHook preInstall

        packageDir="$out/lib/node_modules/billion-context"
        mkdir -p "$packageDir"

        # Extract npm tarball (has prebuilt dist/ and package.json)
        tar -xzf $npmTarball -C "$packageDir" --strip-components=1
        chmod u+w "$packageDir" "$packageDir/package.json"
        sed -i '/"pi": {/,/^[[:space:]]*},/ { /"extensions": \[/,/^[[:space:]]*\],/ s|"./dist/agent/pi-native.js"|"./extensions/billion-context/index.ts"|; }' "$packageDir/package.json"

        # Create a thin TypeScript wrapper that pi-agent can load
        # It re-exports the prebuilt JavaScript implementation
        mkdir -p "$packageDir/extensions/billion-context"
        cat > "$packageDir/extensions/billion-context/index.ts" << 'EOF'
    // Pi agent extension wrapper: loads the prebuilt billion-context implementation
    // The actual code is in dist/agent/pi-native.js (esbuild-bundled)

    import piNativeFactory from "../../dist/agent/pi-native.js";

    export default piNativeFactory;
    EOF

        runHook postInstall
  '';

  passthru = {
    packageDir = "${finalAttrs.finalPackage}/lib/node_modules/billion-context";
    # Point to wrapper TypeScript file for pi-agent discovery
    # The wrapper re-exports from the prebuilt dist/ which includes all dependencies
    extensions = [
      "${finalAttrs.finalPackage}/lib/node_modules/billion-context/extensions/billion-context/index.ts"
    ];
  };

  meta = {
    description = "Context-compression plugin for long-lived coding agents — 5x fewer tokens, billion-token sessions";
    homepage = "https://github.com/ranxianglei/billion-context";
    license = lib.licenses.mit;
    platforms = lib.platforms.all;
    mainProgram = "bili";
  };
})
