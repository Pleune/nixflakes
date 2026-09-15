final: prev:
let
  # https://github.com/LibreOffice/core/blob/a383d7afa4e82bea728ecddf1bc44bbd9fd0eddb/sc/qa/unit/functions_array.cxx#L26
  # https://github.com/NixOS/nixpkgs/issues/398633
  libreofficeOverrides =
    libreoffice:
    libreoffice.override (old: {
      unwrapped = old.unwrapped.overrideAttrs (oldUW: {
        postPatch = (oldUW.postPatch or "") + ''
          sed -i '/CPPUNIT_TEST.testDubiousArrayFormulasFODS/d' sc/qa/unit/functions_array.cxx
        '';
      });
    });
in
{
  #pi-agent = final.callPackage ./pkgs/pi-agent { };
  azure-storage-explorer = final.callPackage ./pkgs/azure-storage-explorer { };
  context-mode = final.callPackage ./pkgs/context-mode { };
  code-review-graph = final.callPackage ./pkgs/code-review-graph { };
  trilium-git-sync = final.callPackage ./pkgs/trilium-git-sync { };
  pi-mcp-adapter = final.callPackage ./pkgs/pi-mcp-adapter { };
  pi-subagents = final.callPackage ./pkgs/pi-subagents { };
  pi-ask = final.callPackage ./pkgs/pi-ask { };
  pi-memory = final.callPackage ./pkgs/pi-memory { };
  pi-hermes-memory = final.callPackage ./pkgs/pi-hermes-memory { };
  pi-quotas = final.callPackage ./pkgs/pi-quotas { };
  pi-token-burden = final.callPackage ./pkgs/pi-token-burden { };
  rpiv-ask-user-question = final.callPackage ./pkgs/rpiv-mono/rpiv-ask-user-question { };
  rpiv-btw = final.callPackage ./pkgs/rpiv-mono/rpiv-btw { };
  incus-backup-rustic = final.callPackage ./pkgs/incus-backup-rustic { };
  keepass-unlocker = final.callPackage ./pkgs/keepass-unlocker { };
  wol_api = final.callPackage ./pkgs/wake-on-lan-api { };
  rpiv-todo = final.callPackage ./pkgs/rpiv-mono/rpiv-todo { };
  rpiv-voice = final.callPackage ./pkgs/rpiv-mono/rpiv-voice { };
  rpiv-warp = final.callPackage ./pkgs/rpiv-mono/rpiv-warp { };

  # https://forums.developer.nvidia.com/t/compilation-errors-with-gcc-versions-11-14-and-cuda-toolkit-12-5-12-6-due-to-undefined-builtin-ia32-ldtilecfg-and-builtin-ia32-sttilecfg-etc/308401/2
  # https://github.com/ggml-org/llama.cpp/issues/9473
  # patch does not work when compiling with F16 support, https://github.com/ggml-org/llama.cpp/pull/9509#issuecomment-2661176283
  # TODO: submit PR / issue
  # llama-cpp = prev.llama-cpp.overrideAttrs (old: {
  #   postPatch =
  #     (old.postPatch or "")
  #     + ''
  #       substituteInPlace ggml/src/ggml-impl.h --replace-fail 'defined(__F16C__)' '0'
  #       substituteInPlace ggml/src/ggml.c --replace-fail '// FIXME: required here for quantization functions' '#include <immintrin.h>'
  #     '';
  # });
  #
  # # same as above
  # ollama = prev.ollama.overrideAttrs (old: {
  #   postPatch =
  #     (old.postPatch or "")
  #     + ''
  #       substituteInPlace llama/ggml-impl.h --replace-fail 'defined(__F16C__)' '0'
  #       substituteInPlace llama/ggml.c --replace-fail '// FIXME: required here for quantization functions' '#include <immintrin.h>'
  #     '';
  # });

  # https://github.com/NixOS/nixpkgs/issues/398621
  opencolorio = prev.opencolorio.overrideAttrs (old: {
    postPatch =
      (old.postPatch or "")
      + final.lib.optionalString (final.stdenv.hostPlatform ? gcc.arch) ''
        sed -i '/add_subdirectory(cpu)/d' tests/CMakeLists.txt
      '';
  });

  # fixed by https://github.com/NixOS/nixpkgs/pull/398581
  lib2geom = prev.lib2geom.overrideAttrs (old: {
    postPatch =
      (old.postPatch or "")
      + final.lib.optionalString (final.stdenv.hostPlatform ? gcc.arch) ''
        sed -i 's/SolveQuartic_Evaluate/DISABLED_SolveQuartic_Evaluate/' tests/polynomial-test.cpp
        sed -i 's/ArcIntersection/DISABLED_ArcIntersection/' tests/elliptical-arc-test.cpp
        sed -i 's/EllipseIntersection/DISABLED_EllipseIntersection/' tests/ellipse-test.cpp
        sed -i 's/CoincidingIntersect/DISABLED_CoincidingIntersect/' tests/line-test.cpp
      '';
  });

  libreoffice-still = libreofficeOverrides prev.libreoffice-still;
  libreoffice-qt-still = libreofficeOverrides prev.libreoffice-qt-still;
  libreoffice-qt6-still = libreofficeOverrides prev.libreoffice-qt6-still;
  libreoffice-fresh = libreofficeOverrides prev.libreoffice-still;
  libreoffice-qt-fresh = libreofficeOverrides prev.libreoffice-qt-still;
  libreoffice-qt6-fresh = libreofficeOverrides prev.libreoffice-qt6-still;
  libreoffice-collabora = libreofficeOverrides prev.libreoffice-collabora;

  pythonPackagesExtensions = prev.pythonPackagesExtensions ++ [
    (pyFinal: pyPrev: {

      # fakeredis = pyPrev.fakeredis.overridePythonAttrs (old: {
      #   postPatch =
      #     (old.postPatch or "")
      #     + ''
      #       substituteInPlace fakeredis/commands_mixins/scripting_mixin.py \
      #         --replace-fail '"5.1": "lupa.lua51"' '"5.1": "lupa.lua"' \
      #         --replace-fail '"5.2": "lupa.lua52"' '"5.2": "lupa.lua"' \
      #         --replace-fail '"5.3": "lupa.lua53"' '"5.3": "lupa.lua"' \
      #         --replace-fail '"5.4": "lupa.lua54"' '"5.4": "lupa.lua"'
      #     '';
      # });

      fastmcp = pyPrev.fastmcp.overridePythonAttrs (old: {
        doCheck = false;
      });

      # TODO: resubmit my patch as mentioned https://github.com/NixOS/nixpkgs/issues/439898#issuecomment-3441105166
      rapidocr-onnxruntime = pyPrev.rapidocr-onnxruntime.overridePythonAttrs (old: {
        disabledTests = old.disabledTests ++ [
          "test_ort_cuda_warning"
          "test_ort_dml_warning"
        ];
      });
    })
  ];

  paperless-gpt = final.callPackage ./pkgs/paperless-gpt { };
}
