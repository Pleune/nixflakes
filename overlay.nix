final: prev: {

  # # random build failures https://github.com/NixOS/nixpkgs/issues/379071
  # gitMinimal = prev.gitMinimal.overrideAttrs { doCheck = false; };

  # https://github.com/NixOS/nixpkgs/pull/380285
  # [----------] Global test environment tear-down
  # [==========] 132 tests from 28 test suites ran. (2 ms total)
  # [  PASSED  ] 131 tests.
  # [  FAILED  ] 1 test, listed below:
  # [  FAILED  ] CORE.known_uarch
  #
  #  1 FAILED TEST
  #
  # 3/3 Test #3: brand-string-test ................   Passed    0.01 sec
  #
  # 67% tests passed, 1 tests failed out of 3
  #
  # Total Test time (real) =   0.01 sec
  #
  # The following tests FAILED:
  #           1 - init-test (Failed)
  # Errors while running CTest
  # make: *** [Makefile:71: test] Error 8

  cpuinfo = prev.cpuinfo.overrideAttrs { doCheck = false; };

  # Fix bcachefs bug causing libuv package test failure until
  # https://github.com/koverstreet/bcachefs/commit/a3ed1cc4136df01e74a8b6df8c562db69e752bad is availaible
  # Fix requirement to not have thread affinity set https://github.com/NixOS/nixpkgs/issues/378438
  libuv = prev.libuv.overrideAttrs (old: {
    postPatch =
      (old.postPatch or "")
      + ''
        sed '/fs_utime_round/d' -i test/test-list.h
        sed '/thread_affinity/d' -i test/test-list.h
      '';
  });

  # https://github.com/NixOS/nixpkgs/pull/380253
  pulseaudio = prev.pulseaudio.overrideAttrs (old: {
    postPatch =
      (old.postPatch or "")
      + ''
        sed -i "/fail_unless(pthread_setaffinity_np.*);/d" src/tests/once-test.c
      '';
  });

  pythonPackagesExtensions = prev.pythonPackagesExtensions ++ [
    (pyFinal: pyPrev: {
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
      numpy = pyPrev.numpy.overridePythonAttrs (old: {
        disabledTests = old.disabledTests ++ [
          "test_validate_transcendentals"
        ];
      });

      # testclient test hangs forever
      starlette = pyPrev.starlette.overridePythonAttrs (old: {
        disabledTestPaths = (old.disabledTestPaths or []) ++ [
          "tests/test_testclient.py"
        ];
      });
    })
  ];
}
