{
  lib,
  buildNpmPackage,
  fetchFromGitHub,
}:
let
  rpivMono = import ../src.nix { inherit fetchFromGitHub; };
in
buildNpmPackage {
  pname = "rpiv-voice";
  inherit (rpivMono) version src npmDepsHash;

  npmDepsFetcherVersion = 2;
  npmWorkspace = "packages/rpiv-voice";

  dontNpmBuild = true;

  installPhase = ''
    runHook preInstall

    packageDir="$out/lib/node_modules/rpiv-voice"
    scopedDir="$out/lib/node_modules/@juicesharp"
    mkdir -p "$packageDir" "$scopedDir"

    cp -r packages/rpiv-voice/. "$packageDir/"

    npm prune --omit=dev --no-save --workspace=packages/rpiv-voice
    find node_modules -type l -lname '*/packages/*' -delete
    find node_modules/.bin -xtype l -delete 2>/dev/null || true
    cp -r node_modules "$packageDir/node_modules"

    ln -s ../rpiv-voice "$scopedDir/rpiv-voice"

    runHook postInstall
  '';

  passthru = {
    packageDir = "${placeholder "out"}/lib/node_modules/@juicesharp/rpiv-voice";
  };

  meta = {
    description = "Pi extension that adds local voice dictation via sherpa-onnx Whisper";
    homepage = "https://github.com/juicesharp/rpiv-mono/tree/main/packages/rpiv-voice";
    license = lib.licenses.mit;
    platforms = lib.platforms.all;
  };
}
