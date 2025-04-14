final: prev:
let

  # https://github.com/LibreOffice/core/blob/a383d7afa4e82bea728ecddf1bc44bbd9fd0eddb/sc/qa/unit/functions_array.cxx#L26
  # https://github.com/NixOS/nixpkgs/issues/398633
  libreofficeOverrides =
    libreoffice:
    libreoffice.override (old: {
      unwrapped = old.unwrapped.overrideAttrs (oldUW: {
        postPatch =
          (oldUW.postPatch or "")
          + ''
            sed -i '/CPPUNIT_TEST.testDubiousArrayFormulasFODS/d' sc/qa/unit/functions_array.cxx
          '';
      });
    });
in
{
  # Fixed by https://github.com/NixOS/nixpkgs/pull/397734
  re2 = prev.re2.overrideAttrs (old: {
    cmakeFlags = (old.cmakeFlags or [ ]) ++ [
      (final.lib.cmakeFeature "CMAKE_CTEST_ARGUMENTS" "--timeout;999999")
    ];
  });

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

  # # random build failures https://github.com/NixOS/nixpkgs/issues/379071
  # gitMinimal = prev.gitMinimal.overrideAttrs { doCheck = false; };

  # https://github.com/NixOS/nixpkgs/issues/398625
  jellyfin-ffmpeg = prev.jellyfin-ffmpeg.overrideAttrs (old: {
    postPatch =
      (old.postPatch or "")
      + final.lib.optionalString (final.stdenv.hostPlatform ? gcc.arch) ''
        sed -i '/fate-vsynth%-huffyuvbgra/d' tests/fate/vcodec.mak
        sed -i 's/huffyuvbgra//' tests/fate/vcodec.mak
      '';
  });

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

  # fixed by https://github.com/NixOS/nixpkgs/pull/382896
  immich-machine-learning = prev.immich-machine-learning.overrideAttrs (old: {
    disabledTests = [
      "test_sets_default_sess_options"
    ];
  });

  pythonPackagesExtensions = prev.pythonPackagesExtensions ++ [
    (pyFinal: pyPrev: {
      # fixed by https://github.com/NixOS/nixpkgs/pull/398569
      numpy_2 = pyPrev.numpy_2.overridePythonAttrs (old: {
        disabledTests =
          old.disabledTests
          ++ final.lib.optionals (final.stdenv.hostPlatform ? gcc.arch) [
            "test_validate_transcendentals"
          ];
      });

      # fixed by https://github.com/scipy/scipy/issues/22495
      # should be good when 1.16.0 is released
      scipy = pyPrev.scipy.overridePythonAttrs (old: {
        disabledTests =
          old.disabledTests
          ++ final.lib.optionals (final.stdenv.hostPlatform ? gcc.arch) [
            "hyp2f1_test_case42"
          ];
      });

      # fixed by https://github.com/NixOS/nixpkgs/pull/382920
      rapidocr-onnxruntime = pyPrev.rapidocr-onnxruntime.overridePythonAttrs (old: {
        disabledTests = old.disabledTests ++ [
          "test_ort_cuda_warning"
          "test_ort_dml_warning"
        ];
      });

      # fixed by https://github.com/NixOS/nixpkgs/pull/396831 https://nixpk.gs/pr-tracker.html?pr=396831
      hypothesis = pyPrev.hypothesis.overridePythonAttrs (old: {
        preCheck =
          (old.preCheck or "")
          + ''
            export HYPOTHESIS_PROFILE=ci
          '';

        disabledTests = (old.disabledTests or [ ]) ++ [
          "test_given_does_not_pollute_state"
          "test_find_does_not_pollute_state"
          "test_does_print_on_reuse_from_database"
          "test_prints_seed_only_on_healthcheck"
        ];

        setupHook = prev.writeText "setup-hook.sh" ''
          hypothesisActivateProfileForCI() {
            export CI=1
          }
          postHooks+=(hypothesisActivateProfileForCI)
        '';
      });
    })
  ];
}
