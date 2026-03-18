{
  stdenv,
  python3,
  keepassxc,
  keyutils,
  fetchFromGitHub,
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
  passthru.keepassxc = keepassxc.overrideAttrs (
    finalAttrs: old: {
      # https://github.com/keepassxreboot/keepassxc/pull/12003
      version = "58aee6f239dc513b6d0e860a5c65d5bd64a54af9";
      src = fetchFromGitHub {
        owner = "keepassxreboot";
        repo = "keepassxc";
        rev = finalAttrs.version;
        hash = "sha256-tFCs+a8RHgk/Z9QiTa0+kpQihGnEgztQgTmW08Up0fo=";
      };
      patches = (old.patches or [ ]) ++ [
        ./keepass--quick-unlock.patch
      ];
      buildInputs = (old.buildInputs or [ ]) ++ [
        keyutils
      ];
    }
  );
}
