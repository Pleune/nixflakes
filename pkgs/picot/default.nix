{
  lib,
  stdenv,
  stdenvNoCC,
  rustPlatform,
  fetchFromGitHub,
  fetchurl,
  cargo-tauri,
  bun,
  jq,
  moreutils,
  nodejs,
  pkg-config,
  wrapGAppsHook3,
  writableTmpDirAsHomeHook,
  glib-networking,
  libayatana-appindicator,
  libsoup_3,
  openssl,
  webkitgtk_4_1,
  librsvg,
  piCodingAgent,
}:
rustPlatform.buildRustPackage (
  finalAttrs:
  let
    terminalFontVersion = "3.4.0";
    cjkFontVersion = "1.522";
  in
  {
    pname = "picot";
    version = "0.5.6";

    __structuredAttrs = true;
    strictDeps = true;

    src = fetchFromGitHub {
      owner = "shixin-guo";
      repo = "picot";
      tag = "v${finalAttrs.version}";
      hash = "sha256-rZb7VZjA3CRtyY/q6t/1x31DR26le0JpAH7nIDrPTh4=";
    };

    terminalFontArchive = fetchurl {
      url = "https://github.com/ryanoasis/nerd-fonts/releases/download/v${terminalFontVersion}/FiraCode.zip";
      hash = "sha256-fMT/2Peh/JFM2rexSYCCmBZf96f0DkDYLeqevkHoygs=";
    };

    cjkFont = fetchurl {
      url = "https://github.com/lxgw/LxgwWenKai-Lite/releases/download/v${cjkFontVersion}/LXGWWenKaiLite-Regular.ttf";
      hash = "sha256-FAyZuk4o6BfOxJv4KgxfzcT+Yz+539oW0O6NWahUXxU=";
    };

    cjkLicense = fetchurl {
      url = "https://raw.githubusercontent.com/lxgw/LxgwWenKai-Lite/v${cjkFontVersion}/OFL.txt";
      hash = "sha256-w4sZlKXkisMKx9HafQQJ/Y/YEn3+KKE9bnh9Wx7zSl4=";
    };

    node_modules = stdenvNoCC.mkDerivation {
      pname = "${finalAttrs.pname}-node_modules";
      inherit (finalAttrs) version src;

      impureEnvVars = lib.fetchers.proxyImpureEnvVars ++ [
        "GIT_PROXY_COMMAND"
        "SOCKS_SERVER"
      ];

      nativeBuildInputs = [
        bun
        writableTmpDirAsHomeHook
      ];

      dontConfigure = true;

      buildPhase = ''
        runHook preBuild

        export BUN_INSTALL_CACHE_DIR=$(mktemp -d)
        bun install \
          --cpu=x64 \
          --os=linux \
          --frozen-lockfile \
          --ignore-scripts \
          --no-progress

        runHook postBuild
      '';

      installPhase = ''
        runHook preInstall

        mkdir -p "$out"
        find . -type d -name node_modules -exec cp -R --parents {} "$out" \;

        runHook postInstall
      '';

      dontFixup = true;

      outputHash = "sha256-HxcGsoocPB/9VYcp9modPOX6wP9mRArHYJisSXgFVrI=";
      outputHashAlgo = "sha256";
      outputHashMode = "recursive";
    };

    cargoRoot = "src-tauri";
    buildAndTestSubdir = finalAttrs.cargoRoot;
    cargoHash = "sha256-rfD8PW3dg04/JnFuRXSi7Zo8JYnKSmNts2lu6mSDG/I=";

    postPatch = ''
      jq '
        del(.build.beforeBuildCommand) |
        del(.build.beforeDevCommand) |
        .bundle.createUpdaterArtifacts = false |
        .plugins.updater.endpoints = []
      ' src-tauri/tauri.conf.json | sponge src-tauri/tauri.conf.json
    ''
    + lib.optionalString stdenv.hostPlatform.isLinux ''
      substituteInPlace $cargoDepsCopy/*/libappindicator-sys-*/src/lib.rs \
        --replace-fail "libayatana-appindicator3.so.1" "${libayatana-appindicator}/lib/libayatana-appindicator3.so.1"
    '';

    nativeBuildInputs = [
      cargo-tauri.hook
      bun
      jq
      moreutils
      nodejs
      pkg-config
      wrapGAppsHook3
      writableTmpDirAsHomeHook
    ];

    buildInputs = [
      glib-networking
      libayatana-appindicator
      libsoup_3
      openssl
      webkitgtk_4_1
      librsvg
    ];

    configurePhase = ''
      runHook preConfigure

      cp -R ${finalAttrs.node_modules}/. .
      chmod -R u+w node_modules
      patchShebangs node_modules

      mkdir -p .cache/terminal-fonts .cache/cjk-fonts src-tauri/resources/pi
      cp ${finalAttrs.terminalFontArchive} .cache/terminal-fonts/${terminalFontVersion}-FiraCode.zip
      cp ${finalAttrs.cjkFont} .cache/cjk-fonts/${cjkFontVersion}-LXGWWenKaiLite-Regular.ttf
      cp ${finalAttrs.cjkLicense} .cache/cjk-fonts/${cjkFontVersion}-OFL.txt
      install -Dm755 ${piCodingAgent}/bin/pi src-tauri/resources/pi/pi

      runHook postConfigure
    '';

    preBuild = ''
      node scripts/fetch-terminal-font.js
      node scripts/fetch-cjk-font.js
      node scripts/build-extensions.js
      node scripts/build-frontend.js
    '';

    # These upstream tests assume a non-sandboxed host environment with writable
    # git worktrees, localhost networking, and external helper binaries.
    checkFlags = [
      "--skip=git_service::tests::binary_diff_detected_as_fallback_reason"
      "--skip=git_service::tests::commit_detached_rejects_stale_index_after_prepare"
      "--skip=git_service::tests::commit_detached_succeeds_for_unborn_repository"
      "--skip=git_service::tests::commit_failure_preserves_hook_stderr"
      "--skip=git_service::tests::detached_commit_captures_snapshot_before_waiting_for_write_slot"
      "--skip=git_service::tests::detached_commit_keeps_expected_tree_after_workspace_cleanup"
      "--skip=git_service::tests::nested_workspace_is_rejected_for_subdirectory_root"
      "--skip=git_service::tests::partial_stage_commit_requires_confirmation_token"
      "--skip=git_service::tests::real_repo_stage_stale_and_discard_preserves_staged"
      "--skip=git_service::tests::revoked_owner_commit_outcome_is_dropped"
      "--skip=git_service::tests::stages_resolved_conflict_from_conflicted_snapshot"
      "--skip=host_server::tests::health_model_test_reports_connectivity_failure_for_unreachable_provider"
      "--skip=host_server::tests::protects_http_data_and_remote_access_by_authority_and_bearer"
      "--skip=markitdown_preview::tests::bounded_runner_streams_stdin_and_rejects_oversized_stdout"
      "--skip=native_pi_manager::tests::unregisters_runtime_when_the_rpc_stream_closes_unexpectedly"
    ];

    meta = {
      description = "Local desktop GUI for the Pi coding agent";
      homepage = "https://github.com/shixin-guo/picot";
      license = lib.licenses.mit;
      mainProgram = "picot";
      platforms = lib.platforms.linux;
    };
  }
)
