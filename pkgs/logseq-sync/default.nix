{
  lib,
  buildNpmPackage,
  fetchFromGitHub,
  git,
  logseq,
  nodejs,
}:
let
  version = "2.3.0";
  # Keep only the store output name, without a Nix store reference. This lets
  # the wrapper opportunistically find Logseq without retaining/building it.
  logseqStoreName = builtins.unsafeDiscardStringContext (builtins.baseNameOf (toString logseq));
  logseqRev = "9eaab9a171ed84088185b4c6b21401c9eeeaecf1";
  sourceHash = "sha256-mx9IK4zKCm4pg61klFcTJJpS/QnDQholr21YUxKw51g=";
  src =
    fetchFromGitHub {
      owner = "geml-spec";
      repo = "geml";
      rev = logseqRev;
      hash = sourceHash;
    }
    + "/integrations/logseq";
in
buildNpmPackage {
  pname = "logseq-sync";
  inherit version src;

  npmDepsFetcherVersion = 2;
  npmDepsHash = "sha256-H7M3kn2zQfuMGV6Yph+bQ//8y34LM9JYo2IWNYX6s70=";
  dontNpmBuild = true;

  nativeBuildInputs = [ git ];
  makeWrapperArgs = [
    "--prefix"
    "PATH"
    ":"
    (lib.makeBinPath [
      git
      nodejs
    ])
  ];

  # npm's workspace install leaves a symlink to the separate Logseq plugin;
  # the published CLI package intentionally ships only the watcher files.
  postInstall = ''
    rm -f "$out/lib/node_modules/@geml/logseq-sync/node_modules/logseq-plugin-sync-vault-with-geml"

    # `nix run .#logseq` launches the GUI but does not add its embedded `logseq`
    # CLI to another `nix run`'s PATH. Keep this as a weak optional reference:
    # adding the complete app to buildInputs would force it to build and retain
    # the full Electron closure even when users run the watcher independently.
    wrapProgram "$out/bin/logseq-sync" \
      --run '
        logseq_store_dir=${builtins.storeDir}
        logseq_store_name=${logseqStoreName}
        logseq_cli_bin="$logseq_store_dir/$logseq_store_name/bin"
        if [ -x "$logseq_cli_bin/logseq" ]; then
          export PATH="$PATH:$logseq_cli_bin"
        fi
      '
  '';

  doCheck = true;
  checkPhase = ''
    runHook preCheck
    # The upstream roundtrip/sync tests import the sibling geml-parser build,
    # which is outside this published integration subtree. Run the self-contained
    # watcher, discovery and plugin tests in this package build instead.
    node core/test/discovery.test.mjs
    node watcher/test/cli-sync.test.mjs
    node watcher/test/signal-sync.test.mjs
    node watcher/test/zero-config.test.mjs
    node plugin/test/core.test.mjs
    runHook postCheck
  '';

  passthru.packageDir = "${placeholder "out"}/lib/node_modules/@geml/logseq-sync";

  meta = {
    description = "Continuously sync a Logseq DB graph to a Git-friendly GEML vault";
    homepage = "https://github.com/geml-spec/geml/tree/main/integrations/logseq";
    license = lib.licenses.mit;
    mainProgram = "logseq-sync";
    platforms = nodejs.meta.platforms;
  };
}
