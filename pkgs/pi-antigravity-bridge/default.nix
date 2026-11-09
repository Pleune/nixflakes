{
  lib,
  buildNpmPackage,
  fetchFromGitHub,
}:
let
  version = "1.9.2";
  rev = "957cb0422272ad06422d0f58bf085030dcd219b7";
in
buildNpmPackage (finalAttrs: {
  pname = "pi-antigravity-bridge";
  inherit version;

  src = fetchFromGitHub {
    owner = "EstebanForge";
    repo = "pi-extensions";
    inherit rev;
    hash = "sha256-iSHhN42G/A7e/UweVHHjDOExaRAtYJP/JfDTqakEzwQ=";
  };

  patches = [
    ./browser-opener-no-recursion.patch
    ./enterprise-auth.patch
  ];

  # Limit the monorepo install to the bridge and its two source-only libraries.
  # Pi supplies its own peer packages; never install a second Pi runtime.
  postPatch = ''
    cat > package.json <<'EOF'
    {
      "name": "pi-antigravity-bridge-workspace",
      "version": "1.0.0",
      "private": true,
      "workspaces": [
        "packages/pi-antigravity-bridge",
        "packages/pi-ask-shared",
        "packages/pi-tui-dialogs"
      ]
    }
    EOF
    cp ${./package-lock.json} package-lock.json
  '';

  npmDepsFetcherVersion = 2;
  npmDepsHash = "sha256-9WkKJfa8EG4GyK5avmdCPHd2SBabkz8MQIhBEvJhgMQ=";
  npmFlags = [ "--legacy-peer-deps" ];
  npmRebuildFlags = [ "--ignore-scripts" ];
  dontNpmBuild = true;

  doCheck = true;
  checkPhase = ''
    runHook preCheck
    node --input-type=module <<'EOF'
    import { Server } from "@modelcontextprotocol/sdk/server/index.js";
    import { StreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/streamableHttp.js";
    import { CallToolRequestSchema } from "@modelcontextprotocol/sdk/types.js";
    import assert from "node:assert/strict";
    assert.equal(typeof Server, "function");
    assert.equal(typeof StreamableHTTPServerTransport, "function");
    assert.ok(CallToolRequestSchema);
    EOF
    test ! -e node_modules/@earendil-works/pi-coding-agent
    node ${./test-browser-capture.mjs} packages/pi-antigravity-bridge/src/acp/browser-capture.ts
    node ${./test-auth-methods.mjs} packages/pi-antigravity-bridge
    runHook postCheck
  '';

  installPhase = ''
    runHook preInstall

    packageDir="$out/lib/node_modules/@estebanforge/pi-antigravity-bridge"
    mkdir -p "$packageDir/extensions/pi-antigravity-bridge"
    cp -r packages/pi-antigravity-bridge/{package.json,extensions,src,README.md,CHANGELOG.md,LICENSE} "$packageDir/"
    cp -r node_modules "$packageDir/"

    # Replace workspace symlinks with real package trees: the monorepo itself
    # is intentionally not part of the installed runtime layout.
    rm -f "$packageDir/node_modules/@estebanforge/"{pi-antigravity-bridge,pi-ask-shared,pi-tui-dialogs}
    for name in pi-ask-shared pi-tui-dialogs; do
      mkdir -p "$packageDir/node_modules/@estebanforge/$name"
      cp -r packages/"$name"/{package.json,src,LICENSE} "$packageDir/node_modules/@estebanforge/$name/"
    done

    cat > "$packageDir/extensions/pi-antigravity-bridge/index.ts" <<'EOF'
    import extension from "../index.ts";
    export default extension;
    EOF
    node - "$packageDir/package.json" <<'EOF'
    const fs = require("node:fs");
    const file = process.argv[2];
    const pkg = JSON.parse(fs.readFileSync(file, "utf8"));
    pkg.pi.extensions = ["./extensions/pi-antigravity-bridge/index.ts"];
    fs.writeFileSync(file, JSON.stringify(pkg, null, 2) + "\n");
    EOF

    ln -s @estebanforge/pi-antigravity-bridge "$out/lib/node_modules/pi-antigravity-bridge"
    runHook postInstall
  '';

  passthru = {
    packageDir = "${finalAttrs.finalPackage}/lib/node_modules/@estebanforge/pi-antigravity-bridge";
    extensions = [
      "${finalAttrs.finalPackage}/lib/node_modules/@estebanforge/pi-antigravity-bridge/extensions/pi-antigravity-bridge/index.ts"
    ];
  };

  meta = {
    description = "Pi provider and tool bridge for Google's Antigravity ACP server and agy CLI";
    homepage = "https://github.com/EstebanForge/pi-extensions/tree/main/packages/pi-antigravity-bridge";
    license = lib.licenses.mit;
    platforms = lib.platforms.all;
  };
})
