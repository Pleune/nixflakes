{
  stdenv,
  incus,
  rustic,
  python3,
}:
stdenv.mkDerivation {
  name = "incus-backup-rustic";
  propagatedBuildInputs = [
    (python3.withPackages (
      pythonPackages: with pythonPackages; [
        python-dateutil
      ]
    ))
    rustic
    incus
  ];
  dontUnpack = true;
  installPhase = "install -Dm755 ${./incus-backup-rustic.py} $out/bin/incus-backup-rustic";
}
