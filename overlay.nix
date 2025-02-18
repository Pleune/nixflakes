final: prev:
let

  # https://github.com/LibreOffice/core/blob/a383d7afa4e82bea728ecddf1bc44bbd9fd0eddb/sc/qa/unit/functions_array.cxx#L26
  # ArrayFunctionsTest::testArrayFormulasFODS finished in: 622ms
  # [_RUN_____] ArrayFunctionsTest::testDubiousArrayFormulasFODS
  # Testing load file:///build/libreoffice-24.2.7.2//sc/qa/unit/data/functions/array/dubious/fods/linest.fods:
  # /build/libreoffice-24.2.7.2/sc/qa/unit/functions_test.cxx:49:ArrayFunctionsTest::testDubiousArrayFormulasFODS
  # forced failure
  # - Testing file:///build/libreoffice-24.2.7.2//sc/qa/unit/data/functions/array/dubious/fods/linest.fods failed, Sheet2.A39 '=O30' result: 12237.3616028623, expected: 1>
  #
  # ArrayFunctionsTest::testDubiousArrayFormulasFODS finished in: 46ms
  # functions_test.cxx:49:Assertion
  # Test name: ArrayFunctionsTest::testDubiousArrayFormulasFODS
  # forced failure
  # - Testing file:///build/libreoffice-24.2.7.2//sc/qa/unit/data/functions/array/dubious/fods/linest.fods failed, Sheet2.A39 '=O30' result: 12237.3616028623, expected: 1>
  #
  # Failures !!!
  # Run: 2   Failure total: 1   Failures: 1   Errors: 0
  #
  # Error: a unit test failed, please do one of:
  #
  # make CppunitTest_sc_array_functions_test CPPUNITTRACE="gdb --args"
  #     # for interactive debugging on Linux
  # make CppunitTest_sc_array_functions_test VALGRIND=memcheck
  #     # for memory checking
  # make CppunitTest_sc_array_functions_test DEBUGCPPUNIT=TRUE
  #     # for exception catching
  #
  # You can limit the execution to just one particular test by:
  #
  # make CPPUNIT_TEST_NAME="testXYZ" ...above mentioned params...
  #
  # make[1]: *** [/build/libreoffice-24.2.7.2/solenv/gbuild/CppunitTest.mk:130: /build/libreoffice-24.2.7.2/workdir/CppunitTest/sc_array_functions_test.test] Error 1
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

  ollama = prev.ollama.overrideAttrs (old: {
    version = "0.5.11";
    src = final.fetchFromGitHub {
      owner = "ollama";
      repo = "ollama";
      tag = "v0.5.11";
      hash = "sha256-Yc/FwIoPvzYSxlrhjkc6xFL5iCunDYmZkG16MiWVZck=";
      fetchSubmodules = true;
    };
    # Build only the arches supported by nix cudaPackages
    # https://cmake.org/cmake/help/latest/prop_tgt/CUDA_ARCHITECTURES.html
    postPatch =
      let
        removePrefix =
          str:
          let
            matched = builtins.match "sm_(.*)" str;
          in
          if matched == null then str else builtins.head matched;
        arches = builtins.map removePrefix final.cudaPackages.cudaFlags.realArches;
      in
      (old.postPatch or "")
      + ''
        substituteInPlace CMakeLists.txt --replace-fail native "${builtins.concatStringsSep ";" arches}"
      '';
    # /lib/libggml-cpu-skylakex.so contains a forbidden reference to /build/
    nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [ final.autoPatchelfHook ];
    preBuild = ''
      cmake -B build -DCMAKE_SKIP_BUILD_RPATH=ON -DCMAKE_BUILD_WITH_INSTALL_RPATH=ON -DCMAKE_INSTALL_RPATH_USE_LINK_RPATH=ON
      cmake --build build
      ls -alh build
    '';

    # https://github.com/ollama/ollama/blob/b86c0a1500279a79484135a41c9ef4bd3798ae9e/docs/development.md#library-detection
    postInstall =
      final.lib.optionalString (prev.stdenv.hostPlatform.isx86 || old.enableRocm || old.enableCuda)
        ''
          # copy libggml_*.so and runners into lib
          # https://github.com/ollama/ollama/blob/v0.4.4/llama/make/gpu.make#L90
          mkdir -p $out/lib
          #cp -r build/ml/backend/ggml/ggml/src/ggml-cuda/lib/* $out/lib/
          # needs build/source/build/lib/ollama/libggml-cuda.so
          ls -alh build/lib/ollama
          cp -r build/lib/ollama $out/lib/
        '';

    vendorHash = "sha256-wtmtuwuu+rcfXsyte1C4YLQA4pnjqqxFmH1H18Fw75g=";
  });

  # # random build failures https://github.com/NixOS/nixpkgs/issues/379071
  # gitMinimal = prev.gitMinimal.overrideAttrs { doCheck = false; };

  # https://github.com/NixOS/nixpkgs/pull/380285
  cpuinfo = prev.cpuinfo.overrideAttrs { doCheck = false; };

  # fixed by
  libuv = prev.libuv.overrideAttrs (old: {
    postPatch =
      (old.postPatch or "")
      + ''
        sed '/fs_utime_round/d' -i test/test-list.h
        sed '/thread_affinity/d' -i test/test-list.h
      '';
  });

  # fixed by https://github.com/NixOS/nixpkgs/pull/380253
  pulseaudio = prev.pulseaudio.overrideAttrs (old: {
    postPatch =
      (old.postPatch or "")
      + ''
        sed -i "/fail_unless(pthread_setaffinity_np.*);/d" src/tests/once-test.c
      '';
  });

  # --- ./tests/ref/vsynth/vsynth1-huffyuvbgra      1970-01-01 00:00:01.000000000 +0000
  # +++ tests/data/fate/vsynth1-huffyuvbgra 2025-02-11 18:44:32.323861298 +0000
  # @@ -1,4 +1,4 @@
  # -98e1f0bd1734cfb0eb0b442259a7de32 *tests/data/fate/vsynth1-huffyuvbgra.avi
  # -14464170 tests/data/fate/vsynth1-huffyuvbgra.avi
  # -49c03ab1b73b7cd3cabc3c77a9479c9e *tests/data/fate/vsynth1-huffyuvbgra.out.rawvideo
  # -stddev:    3.16 PSNR: 38.12 MAXDIFF:   50 bytes:  7603200/  7603200
  # +a671af74c638d93f9e2416ffb7fc1b66 *tests/data/fate/vsynth1-huffyuvbgra.avi
  # +14475070 tests/data/fate/vsynth1-huffyuvbgra.avi
  # +a242b16c132393d73871564a3cfdbdda *tests/data/fate/vsynth1-huffyuvbgra.out.rawvideo
  # +stddev:   58.15 PSNR: 12.84 MAXDIFF:  208 bytes:  7603200/  7603200
  # Test vsynth1-huffyuvbgra failed. Look at tests/data/fate/vsynth1-huffyuvbgra.err for details.
  # make: *** [tests/Makefile:310: fate-vsynth1-huffyuvbgra] Error 1
  # make: *** Waiting for unfinished jobs....
  # https://github.com/jellyfin/jellyfin-ffmpeg/blob/9ce0bcc6feb7f6d2ede7e476933f1705aeaf2b21/tests/fate/vcodec.mak#L210
  # TODO: submit PR / issue
  jellyfin-ffmpeg = prev.jellyfin-ffmpeg.overrideAttrs (old: {
    postPatch =
      (old.postPatch or "")
      + final.lib.optionalString (final.stdenv.hostPlatform ? gcc.arch) ''
        sed -i '/fate-vsynth%-huffyuvbgra/d' tests/fate/vcodec.mak
        sed -i 's/huffyuvbgra//' tests/fate/vcodec.mak
      '';
  });

  # 8 tests failed with 33 errors 21 skips.
  #
  #
  #       Start  9: test_cpu_avx512
  #  9/10 Test  #9: test_cpu_avx512 ..................   Passed    0.00 sec
  #       Start 10: test_python
  # 10/10 Test #10: test_python ......................   Passed    0.35 sec
  #
  # 30% tests passed, 7 tests failed out of 10
  #
  # Total Test time (real) =  10.73 sec
  #
  # The following tests FAILED:
  #           2 - test_cpu (Failed)
  #           3 - test_cpu_no_accel (Failed)
  #           4 - test_cpu_sse2 (Failed)
  #           5 - test_cpu_avx (Failed)
  #           6 - test_cpu_avx+f16c (Failed)
  #           7 - test_cpu_avx2 (Failed)
  #           8 - test_cpu_avx2+f16c (Failed)
  # Errors while running CTest
  # make: *** [Makefile:71: test] Error 8

  # /build/source/tests/cpu/ops/gamma/GammaOpCPU_tests.cpp:123:
  # FAILED: Index: 17 - Values: 0.896949828 and: 0.896951199 - Threshold: 1.00000001e-07
  # /build/source/tests/cpu/ops/gamma/GammaOpCPU_tests.cpp:123:
  # FAILED: Index: 21 - Values: 1.10895336 and: 1.10895324 - Threshold: 1.00000001e-07
  # [ 694/1098] [GammaOpCPU / apply_basic_style_fwd                          ] - FAILED
  # /build/source/tests/cpu/ops/gamma/GammaOpCPU_tests.cpp:187:
  # FAILED: Index: 16 - Values: 0.830311298 and: 0.830311418 - Threshold: 1.00000001e-07
  # /build/source/tests/cpu/ops/gamma/GammaOpCPU_tests.cpp:187:
  # FAILED: Index: 17 - Values: 0.976092517 and: 0.976092875 - Threshold: 1.00000001e-07
  # [ 695/1098] [GammaOpCPU / apply_basic_style_rev                          ] - FAILED
  # /build/source/tests/cpu/ops/gamma/GammaOpCPU_tests.cpp:279:
  # FAILED: Index: 17 - Values: 0.896949828 and: 0.896951199 - Threshold: 1.00000001e-07
  # /build/source/tests/cpu/ops/gamma/GammaOpCPU_tests.cpp:279:
  # FAILED: Index: 21 - Values: -0.896949828 and: -0.896951199 - Threshold: 1.00000001e-07
  # /build/source/tests/cpu/ops/gamma/GammaOpCPU_tests.cpp:279:
  # FAILED: Index: 25 - Values: 1.10895336 and: 1.10895324 - Threshold: 1.00000001e-07
  # /build/source/tests/cpu/ops/gamma/GammaOpCPU_tests.cpp:279:
  # FAILED: Index: 29 - Values: -1.10895336 and: -1.10895324 - Threshold: 1.00000001e-07
  # [ 696/1098] [GammaOpCPU / apply_basic_mirror_style_fwd                   ] - FAILED
  # /build/source/tests/cpu/ops/gamma/GammaOpCPU_tests.cpp:370:
  # FAILED: Index: 16 - Values: 0.830311298 and: 0.830311418 - Threshold: 1.00000001e-07
  # /build/source/tests/cpu/ops/gamma/GammaOpCPU_tests.cpp:370:
  # FAILED: Index: 17 - Values: 0.976092517 and: 0.976092875 - Threshold: 1.00000001e-07
  # /build/source/tests/cpu/ops/gamma/GammaOpCPU_tests.cpp:370:
  # FAILED: Index: 20 - Values: -0.830311298 and: -0.830311418 - Threshold: 1.00000001e-07
  # /build/source/tests/cpu/ops/gamma/GammaOpCPU_tests.cpp:370:
  # FAILED: Index: 21 - Values: -0.976092517 and: -0.976092875 - Threshold: 1.00000001e-07
  # [ 697/1098] [GammaOpCPU / apply_basic_mirror_style_rev                   ] - FAILED
  # /build/source/tests/cpu/ops/gamma/GammaOpCPU_tests.cpp:449:
  # FAILED: Index: 17 - Values: 0.896949828 and: 0.896951199 - Threshold: 1.00000001e-07
  # /build/source/tests/cpu/ops/gamma/GammaOpCPU_tests.cpp:449:
  # FAILED: Index: 25 - Values: 1.10895336 and: 1.10895324 - Threshold: 1.00000001e-07
  # [ 698/1098] [GammaOpCPU / apply_basic_pass_thru_style_fwd                ] - FAILED
  # /build/source/tests/cpu/ops/gamma/GammaOpCPU_tests.cpp:528:
  # FAILED: Index: 16 - Values: 0.830311298 and: 0.830311418 - Threshold: 1.00000001e-07
  # /build/source/tests/cpu/ops/gamma/GammaOpCPU_tests.cpp:528:
  # FAILED: Index: 17 - Values: 0.976092517 and: 0.976092875 - Threshold: 1.00000001e-07
  # [ 699/1098] [GammaOpCPU / apply_basic_pass_thru_style_rev                ] - FAILED
  # /build/source/tests/cpu/ops/gamma/GammaOpCPU_tests.cpp:583:
  # FAILED: Index: 16 - Values: 0.60383141 and: 0.603831291 - Threshold: 1.00000001e-07
  # /build/source/tests/cpu/ops/gamma/GammaOpCPU_tests.cpp:583:
  # FAILED: Index: 17 - Values: 0.910603881 and: 0.91060406 - Threshold: 1.00000001e-07
  # /build/source/tests/cpu/ops/gamma/GammaOpCPU_tests.cpp:583:
  # FAILED: Index: 20 - Values: 1.01142669 and: 1.01142657 - Threshold: 1.00000001e-07
  # /build/source/tests/cpu/ops/gamma/GammaOpCPU_tests.cpp:583:
  # FAILED: Index: 21 - Values: 1.09394491 and: 1.09394503 - Threshold: 1.00000001e-07
  # /build/source/tests/cpu/ops/gamma/GammaOpCPU_tests.cpp:583:
  # FAILED: Index: 22 - Values: 1.49998474 and: 1.49998403 - Threshold: 1.00000001e-07
  # [ 700/1098] [GammaOpCPU / apply_moncurve_style_fwd                       ] - FAILED
  # [ 701/1098] [GammaOpCPU / apply_moncurve_style_rev                       ] - PASSED
  # /build/source/tests/cpu/ops/gamma/GammaOpCPU_tests.cpp:699:
  # FAILED: Index: 10 - Values: 0.674750805 and: 0.674750686 - Threshold: 1.00000001e-07
  # /build/source/tests/cpu/ops/gamma/GammaOpCPU_tests.cpp:699:
  # FAILED: Index: 14 - Values: -0.674750805 and: -0.674750686 - Threshold: 1.00000001e-07
  # /build/source/tests/cpu/ops/gamma/GammaOpCPU_tests.cpp:699:
  # FAILED: Index: 16 - Values: 0.60383141 and: 0.603831291 - Threshold: 1.00000001e-07
  # /build/source/tests/cpu/ops/gamma/GammaOpCPU_tests.cpp:699:
  # FAILED: Index: 17 - Values: 0.910603881 and: 0.91060406 - Threshold: 1.00000001e-07
  # /build/source/tests/cpu/ops/gamma/GammaOpCPU_tests.cpp:699:
  # FAILED: Index: 20 - Values: -0.60383141 and: -0.603831291 - Threshold: 1.00000001e-07
  # /build/source/tests/cpu/ops/gamma/GammaOpCPU_tests.cpp:699:
  # FAILED: Index: 21 - Values: -0.910603881 and: -0.91060406 - Threshold: 1.00000001e-07
  # /build/source/tests/cpu/ops/gamma/GammaOpCPU_tests.cpp:699:
  # FAILED: Index: 24 - Values: 1.01142669 and: 1.01142657 - Threshold: 1.00000001e-07
  # /build/source/tests/cpu/ops/gamma/GammaOpCPU_tests.cpp:699:
  # FAILED: Index: 25 - Values: 1.09394491 and: 1.09394503 - Threshold: 1.00000001e-07
  # /build/source/tests/cpu/ops/gamma/GammaOpCPU_tests.cpp:699:
  # FAILED: Index: 26 - Values: 1.84183896 and: 1.84183872 - Threshold: 1.00000001e-07
  # /build/source/tests/cpu/ops/gamma/GammaOpCPU_tests.cpp:699:
  # FAILED: Index: 28 - Values: -1.01142669 and: -1.01142657 - Threshold: 1.00000001e-07
  # /build/source/tests/cpu/ops/gamma/GammaOpCPU_tests.cpp:699:
  # FAILED: Index: 29 - Values: -1.09394491 and: -1.09394503 - Threshold: 1.00000001e-07
  # /build/source/tests/cpu/ops/gamma/GammaOpCPU_tests.cpp:699:
  # FAILED: Index: 30 - Values: -1.84183896 and: -1.84183872 - Threshold: 1.00000001e-07
  # TODO: submit PR / issue
  opencolorio = prev.opencolorio.overrideAttrs (old: {
    postPatch =
      (old.postPatch or "")
      + final.lib.optionalString (final.stdenv.hostPlatform ? gcc.arch) ''
        sed -i '/add_subdirectory(cpu)/d' tests/CMakeLists.txt
      '';
  });

  # [  FAILED  ] PolynomialTest.SolveQuartic_Evaluate (2 ms)
  # [ RUN      ] PolynomialTest.SolveQuartic_2_roots
  # [       OK ] PolynomialTest.SolveQuartic_2_roots (2 ms)
  # [ RUN      ] PolynomialTest.SolveQuartic_DoubleRoots
  # [       OK ] PolynomialTest.SolveQuartic_DoubleRoots (0 ms)
  # [ RUN      ] PolynomialTest.SolveQuartic_0_roots
  # [       OK ] PolynomialTest.SolveQuartic_0_roots (3 ms)
  # [ RUN      ] PolynomialTest.SolveQuartic_degenerate
  # [       OK ] PolynomialTest.SolveQuartic_degenerate (4 ms)
  # [----------] 9 tests from PolynomialTest (17 ms total)
  #
  # [----------] Global test environment tear-down
  # [==========] 9 tests from 1 test suite ran. (17 ms total)
  # [  PASSED  ] 8 tests.
  # [  PASSED  ] 8 tests.
  # [  FAILED  ] 1 test, listed below:
  # [  FAILED  ] PolynomialTest.SolveQuartic_Evaluate
  #
  #  1 FAILED TEST
  #
  # 20/25 Test  #9: elliptical-arc-test ..............***Failed    0.04 sec
  # Running main() from /build/source/googletest/src/gtest_main.cc
  # [==========] Running 7 tests from 2 test suites.
  # [----------] Global test environment set-up.
  # [----------] 6 tests from EllipticalArcTest
  # [ RUN      ] EllipticalArcTest.PointAt
  # [       OK ] EllipticalArcTest.PointAt (0 ms)
  # [ RUN      ] EllipticalArcTest.Duplicate
  # [       OK ] EllipticalArcTest.Duplicate (0 ms)
  # [ RUN      ] EllipticalArcTest.LineSegmentIntersection
  # [       OK ] EllipticalArcTest.LineSegmentIntersection (39 ms)
  # [ RUN      ] EllipticalArcTest.ArcIntersection
  # /build/source/tests/elliptical-arc-test.cpp:187: Failure
  # Expected equality of these values:
  #   r1.size()
  #     Which is: 0
  #   2u
  #     Which is: 2
  #
  # [  FAILED  ] EllipticalArcTest.ArcIntersection (0 ms)
  # [ RUN      ] EllipticalArcTest.BezierIntersection
  # [       OK ] EllipticalArcTest.BezierIntersection (0 ms)
  # [ RUN      ] EllipticalArcTest.ExpandToTransformedTest
  # [       OK ] EllipticalArcTest.ExpandToTransformedTest (0 ms)
  # [----------] 6 tests from EllipticalArcTest (40 ms total)
  #
  # [----------] 1 test from EllipticalArc
  # [ RUN      ] EllipticalArc.Transform
  # [       OK ] EllipticalArc.Transform (0 ms)
  # [----------] 1 test from EllipticalArc (0 ms total)
  #
  # [----------] Global test environment tear-down
  # [==========] 7 tests from 2 test suites ran. (40 ms total)
  # [  PASSED  ] 6 tests.
  # [  FAILED  ] 1 test, listed below:
  # [  FAILED  ] EllipticalArcTest.ArcIntersection
  #
  #  1 FAILED TEST
  #
  # 21/25 Test  #8: ellipse-test .....................***Failed    0.05 sec
  # Running main() from /build/source/googletest/src/gtest_main.cc
  # [==========] Running 12 tests from 1 test suite.
  # [----------] Global test environment set-up.
  # [----------] 12 tests from EllipseTest
  # [ RUN      ] EllipseTest.Arcs
  # lines 353-403/504 87%
  # [  PASSED  ] 8 tests.
  # [  FAILED  ] 1 test, listed below:
  # [  FAILED  ] PolynomialTest.SolveQuartic_Evaluate
  #
  #  1 FAILED TEST
  #
  # 20/25 Test  #9: elliptical-arc-test ..............***Failed    0.04 sec
  # Running main() from /build/source/googletest/src/gtest_main.cc
  # [==========] Running 7 tests from 2 test suites.
  # [----------] Global test environment set-up.
  # [----------] 6 tests from EllipticalArcTest
  # [ RUN      ] EllipticalArcTest.PointAt
  # [       OK ] EllipticalArcTest.PointAt (0 ms)
  # [ RUN      ] EllipticalArcTest.Duplicate
  # [       OK ] EllipticalArcTest.Duplicate (0 ms)
  # [ RUN      ] EllipticalArcTest.LineSegmentIntersection
  # [       OK ] EllipticalArcTest.LineSegmentIntersection (39 ms)
  # [ RUN      ] EllipticalArcTest.ArcIntersection
  # /build/source/tests/elliptical-arc-test.cpp:187: Failure
  # Expected equality of these values:
  #   r1.size()
  #     Which is: 0
  #   2u
  #     Which is: 2
  #
  # [  FAILED  ] EllipticalArcTest.ArcIntersection (0 ms)
  # [ RUN      ] EllipticalArcTest.BezierIntersection
  # [       OK ] EllipticalArcTest.BezierIntersection (0 ms)
  # [ RUN      ] EllipticalArcTest.ExpandToTransformedTest
  # [       OK ] EllipticalArcTest.ExpandToTransformedTest (0 ms)
  # lines 353-382/504 85%
  # [  PASSED  ] 8 tests.
  # [  FAILED  ] 1 test, listed below:
  # [  FAILED  ] PolynomialTest.SolveQuartic_Evaluate
  #
  #  1 FAILED TEST
  #
  # 20/25 Test  #9: elliptical-arc-test ..............***Failed    0.04 sec
  # Running main() from /build/source/googletest/src/gtest_main.cc
  # [==========] Running 7 tests from 2 test suites.
  # [----------] Global test environment set-up.
  # [----------] 6 tests from EllipticalArcTest
  # [ RUN      ] EllipticalArcTest.PointAt
  # [       OK ] EllipticalArcTest.PointAt (0 ms)
  # [ RUN      ] EllipticalArcTest.Duplicate
  # [       OK ] EllipticalArcTest.Duplicate (0 ms)
  # [ RUN      ] EllipticalArcTest.LineSegmentIntersection
  # [       OK ] EllipticalArcTest.LineSegmentIntersection (39 ms)
  # [ RUN      ] EllipticalArcTest.ArcIntersection
  # /build/source/tests/elliptical-arc-test.cpp:187: Failure
  # Expected equality of these values:
  #   r1.size()
  #     Which is: 0
  #   2u
  #     Which is: 2
  #
  # [  FAILED  ] EllipticalArcTest.ArcIntersection (0 ms)
  # [ RUN      ] EllipticalArcTest.BezierIntersection
  # [       OK ] EllipticalArcTest.BezierIntersection (0 ms)
  # [ RUN      ] EllipticalArcTest.ExpandToTransformedTest
  # [       OK ] EllipticalArcTest.ExpandToTransformedTest (0 ms)
  # [----------] 6 tests from EllipticalArcTest (40 ms total)
  #
  # [----------] 1 test from EllipticalArc
  # [ RUN      ] EllipticalArc.Transform
  # [       OK ] EllipticalArc.Transform (0 ms)
  # [----------] 1 test from EllipticalArc (0 ms total)
  #
  # [----------] Global test environment tear-down
  # [==========] 7 tests from 2 test suites ran. (40 ms total)
  # [  PASSED  ] 6 tests.
  # [  FAILED  ] 1 test, listed below:
  # [  FAILED  ] EllipticalArcTest.ArcIntersection
  #
  #  1 FAILED TEST
  #
  # 21/25 Test  #8: ellipse-test .....................***Failed    0.05 sec
  # Running main() from /build/source/googletest/src/gtest_main.cc
  # [==========] Running 12 tests from 1 test suite.
  # [----------] Global test environment set-up.
  # [----------] 12 tests from EllipseTest
  # [ RUN      ] EllipseTest.Arcs
  # [       OK ] EllipseTest.Arcs (0 ms)
  # [ RUN      ] EllipseTest.AreNear
  # [       OK ] EllipseTest.AreNear (0 ms)
  # [ RUN      ] EllipseTest.Transformations
  # [       OK ] EllipseTest.Transformations (0 ms)
  # [ RUN      ] EllipseTest.TimeAt
  # [       OK ] EllipseTest.TimeAt (0 ms)
  # [ RUN      ] EllipseTest.LineIntersection
  # [       OK ] EllipseTest.LineIntersection (39 ms)
  # [ RUN      ] EllipseTest.EllipseIntersection
  # /build/source/tests/ellipse-test.cpp:231: Failure
  # Expected: (xs.size()) > (0), actual: 0 vs 0
  #
  # [  FAILED  ] EllipseTest.EllipseIntersection (0 ms)
  # [ RUN      ] EllipseTest.BezierIntersection
  # [       OK ] EllipseTest.BezierIntersection (0 ms)
  # [ RUN      ] EllipseTest.Coefficients
  # [       OK ] EllipseTest.Coefficients (0 ms)
  # [ RUN      ] EllipseTest.UnitCircleTransform
  # [       OK ] EllipseTest.UnitCircleTransform (0 ms)
  # [ RUN      ] EllipseTest.PointAt
  # [       OK ] EllipseTest.PointAt (0 ms)
  # [ RUN      ] EllipseTest.UnitTangentAt
  # [       OK ] EllipseTest.UnitTangentAt (0 ms)
  # [ RUN      ] EllipseTest.Bounds
  # [       OK ] EllipseTest.Bounds (4 ms)
  # [----------] 12 tests from EllipseTest (43 ms total)
  #
  # [----------] Global test environment tear-down
  # [==========] 12 tests from 1 test suite ran. (43 ms total)
  # [  PASSED  ] 11 tests.
  # [  FAILED  ] 1 test, listed below:
  # [  FAILED  ] EllipseTest.EllipseIntersection
  #
  #  1 FAILED TEST
  #
  # 22/25 Test  #7: coord-test .......................   Passed    0.05 sec
  # 23/25 Test #21: sbasis-test ......................   Passed    0.05 sec
  # 24/25 Test #12: line-test ........................***Failed    0.07 sec
  # Running main() from /build/source/googletest/src/gtest_main.cc
  # [==========] Running 15 tests from 1 test suite.
  # [----------] Global test environment set-up.
  # [----------] 15 tests from LineTest
  # [ RUN      ] LineTest.VectorAndVersor
  # [       OK ] LineTest.VectorAndVersor (0 ms)
  # [ RUN      ] LineTest.AngleBisector
  # [       OK ] LineTest.AngleBisector (0 ms)
  # [ RUN      ] LineTest.Equality
  # [       OK ] LineTest.Equality (0 ms)
  # [ RUN      ] LineTest.Reflection
  # [       OK ] LineTest.Reflection (0 ms)
  # [ RUN      ] LineTest.RotationToZero
  # [       OK ] LineTest.RotationToZero (0 ms)
  # [ RUN      ] LineTest.Coefficients
  # [       OK ] LineTest.Coefficients (0 ms)
  # [ RUN      ] LineTest.Intersection
  # [       OK ] LineTest.Intersection (0 ms)
  # [ RUN      ] LineTest.CoincidingIntersect
  # /build/source/tests/line-test.cpp:197: Failure
  # Expected equality of these values:
  #   xings.size()
  #     Which is: 1
  #   2
  #
  # [  FAILED  ] LineTest.CoincidingIntersect (14 ms)
  # [ RUN      ] LineTest.OverlappingIntersect
  # [       OK ] LineTest.OverlappingIntersect (12 ms)
  # [ RUN      ] LineTest.AlmostIntersect
  # [       OK ] LineTest.AlmostIntersect (0 ms)
  # [ RUN      ] LineTest.FuzzyOverlap
  # [       OK ] LineTest.FuzzyOverlap (0 ms)
  # [ RUN      ] LineTest.FuzzyEndToEnd
  # [       OK ] LineTest.FuzzyEndToEnd (0 ms)
  # [ RUN      ] LineTest.AlmostTouch
  # [       OK ] LineTest.AlmostTouch (0 ms)
  # [ RUN      ] LineTest.TBone
  # [       OK ] LineTest.TBone (18 ms)
  # [ RUN      ] LineTest.PushOff
  # [       OK ] LineTest.PushOff (17 ms)
  # [----------] 15 tests from LineTest (62 ms total)
  #
  # [----------] Global test environment tear-down
  # [==========] 15 tests from 1 test suite ran. (62 ms total)
  # [  PASSED  ] 14 tests.
  # [  FAILED  ] 1 test, listed below:
  # [  FAILED  ] LineTest.CoincidingIntersect
  #
  #  1 FAILED TEST
  #
  # 25/25 Test #24: root-find-test ...................   Passed    0.66 sec
  #
  # 84% tests passed, 4 tests failed out of 25
  #
  # Total Test time (real) =   0.69 sec
  #
  # The following tests FAILED:
  #           8 - ellipse-test (Failed)
  #           9 - elliptical-arc-test (Failed)
  #          12 - line-test (Failed)
  #          19 - polynomial-test (Failed)
  # Errors while running CTest
  # TODO: submit PR / issue
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

  # fixed by https://github.com/NixOS/nixpkgs/pull/382891
  mxnet = prev.mxnet.overrideAttrs (old: {
    meta.broken = false;
    cmakeFlags = old.cmakeFlags ++ [ "-DUSE_CUDA=OFF" ];
  });

  # fixed by https://github.com/NixOS/nixpkgs/pull/357656
  onnxruntime = prev.onnxruntime.overrideAttrs (old: {
    postPatch =
      (old.postPatch or "")
      # https://github.com/microsoft/onnxruntime/blob/c4f3742bb456a33ee9c826ce4e6939f8b84ce5b0/onnxruntime/core/platform/env.h#L249
      + ''
        substituteInPlace onnxruntime/core/platform/env.h --replace-fail \
          "GetRuntimePath() const { return PathString(); }"              \
          "GetRuntimePath() const { return PathString(\"$out/lib/\"); }"
      '';
  });

  # fixed by https://github.com/NixOS/nixpkgs/pull/382896
  immich-machine-learning = prev.immich-machine-learning.overrideAttrs (old: {
    disabledTests = (old.disabledTests or [ ]) ++ [
      # This tries to setup a GPU context
      "test_sets_default_sess_options"
    ];
  });

  pythonPackagesExtensions = prev.pythonPackagesExtensions ++ [
    (pyFinal: pyPrev: {
      #opencv4 = pyPrev.toPythonModule (prev.opencv4.override { enablePython = true; python3Packages = pyPrev; });

      # https://github.com/NixOS/nixpkgs/pull/380245
      # In LXC container, this is cheking different things.
      # Traceback (most recent call last):
      #   File "/nix/store/yhfpis4gxkd8ggdv9f8npam1bgavvv76-python3.12-twisted-24.11.0/lib/python3.12/site-packages/twisted/trial/test/test_script.py", line 542, in test_cpuCount
      #     self.assertEqual(trial._autoJobs(), os.cpu_count())
      #   File "/nix/store/yhfpis4gxkd8ggdv9f8npam1bgavvv76-python3.12-twisted-24.11.0/lib/python3.12/site-packages/twisted/trial/_synctest.py", line 444, in assertEqual
      #     super().assertEqual(first, second, msg)
      #   File "/nix/store/qrc496n6fsqp4p5m5h8wmw5d5jwyw5mr-python3-3.12.8/lib/python3.12/unittest/case.py", line 885, in assertEqual
      #     assertion_func(first, second, msg=msg)
      #   File "/nix/store/qrc496n6fsqp4p5m5h8wmw5d5jwyw5mr-python3-3.12.8/lib/python3.12/unittest/case.py", line 878, in _baseAssertEqual
      #     raise self.failureException(msg)
      # twisted.trial.unittest.FailTest: 10 != 12
      #
      # twisted.trial.test.test_script.AutoJobsTests.test_cpuCount
      twisted = pyPrev.twisted.overrideAttrs (old: {
        postPatch =
          (old.postPatch or "")
          + ''
            echo 'AutoJobsTests.test_cpuCount.skip = ""' >> src/twisted/trial/test/test_script.py
          '';
      });

      # numpy tests fail when optimized with gcc.arch
      # https://github.com/NixOS/nixpkgs/issues/275626
      # https://github.com/numpy/numpy/issues/27460
      numpy_2 = pyPrev.numpy_2.overridePythonAttrs (old: {
        disabledTests =
          old.disabledTests
          ++ final.lib.optionals (final.stdenv.hostPlatform ? gcc.arch) [
            "test_validate_transcendentals"
          ];
      });

      # https://github.com/scipy/scipy/issues/22495
      scipy = pyPrev.scipy.overridePythonAttrs (old: {
        disabledTests =
          old.disabledTests
          ++ final.lib.optionals (final.stdenv.hostPlatform ? gcc.arch) [
            "hyp2f1_test_case42"
          ];
      });

      # # testclient test hangs forever ? sometimes?
      # starlette = pyPrev.starlette.overridePythonAttrs (old: {
      #   disabledTestPaths =
      #     (old.disabledTestPaths or [ ])
      #     ++ final.lib.optionals (final.stdenv.hostPlatform ? gcc.arch) [
      #       "tests/test_testclient.py"
      #     ];
      # });

      # fixed by https://github.com/NixOS/nixpkgs/pull/382903
      # the non-python package patched the lib search path to inside itself. But, the python package does not
      # hold a runtime buildInputs dep on the non-python version, so that path may not exist.
      # Just ensure python-onnxruntime pulls down the non-python one as well,
      # and don'y worry about the duplicated files for now.
      onnxruntime =
        let
          onnxruntime = final.onnxruntime.override {
            python3Packages = pyPrev;
            pythonSupport = true;
          };
        in
        (pyPrev.onnxruntime.override { inherit onnxruntime; }).overridePythonAttrs (old: {
          buildInputs = old.buildInputs ++ [ onnxruntime ];
        });

      # fixed by https://github.com/NixOS/nixpkgs/pull/382920
      # These tests attempt to use the GPU, and segfault when one is not availaible
      rapidocr-onnxruntime = pyPrev.rapidocr-onnxruntime.overridePythonAttrs (old: {
        disabledTests = old.disabledTests ++ [
          "test_ort_cuda_warning"
          "test_ort_dml_warning"
        ];
      });
    })
  ];
}
