{
  stdenv,
  python3,
  keepassxc,
}:
stdenv.mkDerivation {
  name = "keepass-unlocker";
  propagatedBuildInputs = [
    (python3.withPackages (
      pythonPackages: with pythonPackages; [
        dbus-python
        pygobject3
        keyring
        psutil
      ]
    ))
  ];
  dontUnpack = true;
  installPhase = "install -Dm755 ${./keepass-unlocker.py} $out/bin/keepass-unlocker";
  # keepassxc with the quick-unlock patch on top of whatever nixpkgs provides.
  # The patch is still needed: upstream keepassxc has no `--quick-unlock` flag and
  # org.keepassxc.KeePassXC.MainWindow/openDatabase only takes (fileName, pw, keyFile),
  # while keepass-unlocker.py calls it with a 4th `enableQuickUnlock` boolean, and
  # enterKey() always blocks quick unlock for programmatically supplied keys.
  # See https://github.com/keepassxreboot/keepassxc/pull/12003
  #
  # keepass--quick-unlock.patch is rebased onto nixpkgs' current keepassxc (2.8.0).
  # When nixpkgs bumps keepassxc and the patch stops applying, rebase it again
  # instead of pinning an old revision. The old pin (58aee6f239dc, 2.7.4+) also
  # carried a botan `ec_group` include fix and a keyutils input; both are upstream
  # / provided by nixpkgs now, so they were dropped.
  passthru.keepassxc = keepassxc.overrideAttrs (
    _: old: {
      patches = (old.patches or [ ]) ++ [ ./keepass--quick-unlock.patch ];
    }
  );
}
