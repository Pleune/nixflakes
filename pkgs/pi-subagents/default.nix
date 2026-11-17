{
  lib,
  stdenvNoCC,
  fetchFromGitHub,
  fetchurl,
  makeWrapper,
  nodejs,
}:
let
  version = "0.88.0";

  src = fetchFromGitHub {
    owner = "nicobailon";
    repo = "pi-subagents";
    rev = "c99503aed6d6b20d2397a1767f7d60730efe3963";
    hash = "sha256-DPeu8UEl0Oq+m3YirA4vXOaDmyyIVMkxBzMXEWrmVHo=";
  };

  # Upstream ships unbundled TypeScript source, so the runtime npm dependencies
  # are attached as registry tarballs and unpacked into the package's own
  # node_modules instead of running an npm install. `hash` is the npm
  # dist.integrity (sha512 SRI) of the tarball. `alias` overrides the
  # node_modules directory a tarball is unpacked into when it should differ
  # from the published package name.
  runtimeDeps = [
    # Lazy runtime dependency of src/runs/background/calendar-schedule.ts.
    {
      name = "@js-temporal/polyfill";
      version = "0.5.1";
      hash = "sha512-hloP58zRVCRSpgDxmqCWJNlizAlUgJFqG2ypq79DCvyv9tHjRYMDOcPFjzfl/A1/YxDvRCZz8wvZvmapQnKwFQ==";
    }
    # Resolved by workflow-script-process.cjs to parse workflow scripts.
    {
      name = "acorn";
      version = "8.18.0";
      hash = "sha512-lGq+9yr1/GuAWaVYIHRjvvySG5/4VfKIvC8EWxStPdcDh/Ka7FG3twP6v4d5BkravUilhIAsG4Qj83t02LWUPQ==";
    }
    # Runtime dependency of @js-temporal/polyfill.
    {
      name = "jsbi";
      version = "4.3.2";
      hash = "sha512-9fqMSQbhJykSeii05nxKl4m6Eqn2P6rOlYiS+C5Dr/HPIU/7yZxu5qzbs40tgaFORiw2Amd0mirjxatXYMkIew==";
    }
    # Runs the TypeScript subagent runner in background processes.
    {
      name = "jiti";
      version = "2.7.0";
      hash = "sha512-AC/7JofJvZGrrneWNaEnJeOLUx+JlGt7tNa0wZiRPT4MY1wmfKjt2+6O2p2uz2+skll8OZZmJMNqeke7kKbNgQ==";
    }
    # Peer dependency upstream publishes as a devDependency; pi-subagents
    # imports `typebox`, `typebox/compile`, and `typebox/value` at runtime.
    {
      name = "typebox";
      version = "1.3.27";
      hash = "sha512-zu+jc1pcy4UiNThxikUr36f0Rybk9PEeCg/NE6adeWr/SKsdNO4EzZHYRDlv2YCVAfj3Odq3dESSo/jNyoBXzA==";
    }
    # Proxy-aware dispatcher installed by src/runs/background/runner-http-dispatcher.ts.
    {
      name = "undici";
      version = "8.12.4";
      hash = "sha512-8Mx+uNKKER2bA4AdtedkqRbwUCIJFr2nJckXRe5yrDqzePqwLP7VNcctN8/XdmDSbF7mS+jJKIszlL+vbam1VA==";
    }
    # Agent/skill frontmatter parsing and serialization.
    {
      name = "yaml";
      version = "2.8.3";
      hash = "sha512-AvbaCLOO2Otw/lW5bmh9d/WEdcDFdQp2Z2ZUH3pX9U2ihyUY0nvLv7J6TrWowklRGPYbB/IuIMfYgxaCPg5Bpg==";
    }
  ];

  # Scoped npm tarballs are published under their unscoped basename, e.g.
  # @js-temporal/polyfill -> .../-/polyfill-0.5.1.tgz.
  tarballName = name: lib.last (lib.splitString "/" name);

  depTarball =
    dep:
    fetchurl {
      url = "https://registry.npmjs.org/${dep.name}/-/${tarballName dep.name}-${dep.version}.tgz";
      hash = dep.hash;
    };

  putAssets = lib.concatMapStringsSep "\n" (dep: ''
    putAsset "${dep.alias or dep.name}" ${depTarball dep}
  '') runtimeDeps;
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

        # Unpack a dependency tarball into node_modules/<name>, dropping the
        # tarball's top-level `package/` directory.
        putAsset() {
          mkdir -p "$nodeModulesDir/$1"
          tar -xzf "$2" --strip-components=1 -C "$nodeModulesDir/$1"
        }

        ${putAssets}

        mkdir -p "$packageDir/extensions/pi-subagents"
        cat > "$packageDir/extensions/pi-subagents/index.ts" <<'EOF'
    import extension from "../../index.ts";
    export default extension;
    EOF
        sed -i '/"pi": {/,/^[[:space:]]*},/ { /"extensions": \[/,/^[[:space:]]*\],/ s|"./index.ts"|"./extensions/pi-subagents/index.ts"|; }' "$packageDir/package.json"

        makeWrapper ${nodejs}/bin/node "$out/bin/pi-subagents" \
          --add-flags "$packageDir/install.mjs" \
          --set-default NODE_PATH "$nodeModulesDir"

        runHook postInstall
  '';

  passthru = {
    packageDir = "${finalAttrs.finalPackage}/lib/node_modules/pi-subagents";
    extensions = [
      "${finalAttrs.finalPackage}/lib/node_modules/pi-subagents/extensions/pi-subagents/index.ts"
    ];
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
