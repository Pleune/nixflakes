{
  lib,
  python3,
  fetchFromGitHub,
  fetchpatch,
}:

python3.pkgs.buildPythonApplication rec {
  pname = "wake-on-lan-api";
  version = "1.0.7";

  pyproject = true;

  src = fetchFromGitHub {
    owner = "rix1337";
    repo = "WakeOnLAN-API";
    rev = "v.${version}";
    hash = "sha256-7OilDFYo+fM7v/ev0Ck/JCkAqscd99XRswDDWYZr+fo=";
  };

  build-system = with python3.pkgs; [ setuptools ];

  dependencies =
    with python3.pkgs;
    [ bottle wakeonlan ];

  # requirements.txt has exact versions listed for no reason
  dontCheckRuntimeDeps = true;

  meta = with lib; {
    description = "Wake on lan utility server";
    homepage = "https://github.com/rix1337/WakeOnLAN-API";
    license = licenses.mit;
    mainProgram = "wol_api";
  };
}
