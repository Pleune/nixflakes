{
  lib,
  buildNpmPackage,
  fetchFromGitHub,
  makeWrapper,
  nodejs,
  typescript,
  typescript-go,
  pkg-config,
  pixman,
  cairo,
  pango,
  libpng,
  libjpeg,
  giflib,
  librsvg,
  fd,
  gitMinimal,
  openssh,
  ripgrep,
}:
let
  version = "0.80.2";
  runtimeBins = lib.makeBinPath [
    nodejs
    gitMinimal
    openssh
    ripgrep
    fd
  ];
  src = fetchFromGitHub {
    owner = "earendil-works";
    repo = "pi";
    rev = "v${version}";
    hash = "sha256-aKtgPc3rwHEp856jP3N7nImph0CSG+gsWq9OVci3hmE=";
  };
  npmDepsHash = "sha256-1EGs8lX8XoAnRtS+pw4lBRm24U/vtVB2loVRmZyd4Z8=";

  drv = buildNpmPackage {
    pname = "pi-agent";
    inherit src version npmDepsHash;

    patches = [
      ./0001-merge-explicit-and-discovered-append-system-prompts.patch
    ];

    nativeBuildInputs = [
      makeWrapper
      pkg-config
      typescript
      typescript-go
    ];

    buildInputs = [
      pixman
      cairo
      pango
      libpng
      libjpeg
      giflib
      librsvg
      fd
    ];

    postPatch = ''
      cp ${./package-lock.json} package-lock.json
    '';

    preBuild = ''
      find packages -name "package.json" -exec sed -i \
        -e 's/--watch --preserveWatchOutput//g' \
        {} \;

      for f in packages/ai/src/models.ts packages/agent/src/agent.ts packages/tui/src/utils.ts; do
        [ -f "$f" ] && echo '// @ts-nocheck' | cat - "$f" > tmp && mv tmp "$f"
      done

      substituteInPlace packages/coding-agent/src/modes/interactive/interactive-mode.ts \
        --replace-fail $'\tshowNewVersionNotification(release: LatestPiRelease): void {\n\t\tconst action = theme.fg("accent", `''${APP_NAME} update`);\n\t\tconst updateInstruction = theme.fg("muted", `New version ''${release.version} is available. Run `) + action;' \
                       $'\tshowNewVersionNotification(release: LatestPiRelease): void {\n\t\tconst action = theme.fg("accent", `https://github.com/earendil-works/pi/releases/tag/v''${release.version}`);\n\t\tconst updateInstruction = theme.fg("muted", `New version ''${release.version} is available. See `) + action;'

      changelogReplacement='`https://github.com/earendil-works/pi/blob/v''${release.version}/packages/coding-agent/CHANGELOG.md`'
      for changelogUrl in \
        '"https://pi.dev/changelog"' \
        '"https://github.com/badlogic/pi-mono/blob/main/packages/coding-agent/CHANGELOG.md"' \
        '"https://github.com/earendil-works/pi-mono/blob/main/packages/coding-agent/CHANGELOG.md"'
      do
        if grep -qF "$changelogUrl" packages/coding-agent/src/modes/interactive/interactive-mode.ts; then
          substituteInPlace packages/coding-agent/src/modes/interactive/interactive-mode.ts \
            --replace-fail "$changelogUrl" "$changelogReplacement"
        fi
      done

      cp ${./models.generated.ts} packages/ai/src/models.generated.ts

      substituteInPlace packages/ai/package.json \
        --replace-fail 'npm run generate-models && ' '''
    '';

    buildPhase = ''
      runHook preBuild
      npm run build --workspace=packages/tui --workspace=packages/ai --workspace=packages/agent --workspace=packages/coding-agent
      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      mkdir -p $out/bin $out/lib/node_modules/@earendil-works

      for pkg in tui ai agent coding-agent mom pods; do
        [ -d "packages/$pkg/dist" ] || continue
        mkdir -p "$out/lib/node_modules/@earendil-works/pi-$pkg"
        cp -r packages/$pkg/dist/* "$out/lib/node_modules/@earendil-works/pi-$pkg/"
        cp packages/$pkg/package.json "$out/lib/node_modules/@earendil-works/pi-$pkg/"
      done

      cp -rL node_modules/. "$out/lib/node_modules/"

      makeWrapper ${nodejs}/bin/node $out/bin/pi \
        --add-flags "$out/lib/node_modules/@earendil-works/pi-coding-agent/dist/cli.js" \
        --set PI_PACKAGE_DIR "$out/lib/node_modules/@earendil-works/pi-coding-agent" \
        --prefix NODE_PATH : "$out/lib/node_modules" \
        --suffix PATH : "${runtimeBins}" \
        --run 'export NPM_CONFIG_PREFIX="''${NPM_CONFIG_PREFIX:-''${XDG_DATA_HOME:-$HOME/.local/share}/pi/npm}"'
      runHook postInstall
    '';

    meta = {
      description = "Pi - a minimal terminal coding harness";
      homepage = "https://github.com/earendil-works/pi";
      license = lib.licenses.mit;
      mainProgram = "pi";
      maintainers = [ ];
      platforms = lib.platforms.linux;
    };
  };
in
drv
