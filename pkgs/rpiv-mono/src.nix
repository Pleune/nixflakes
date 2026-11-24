{
  fetchFromGitHub,
  applyPatches,
}:
let
  version = "2.15.0";

  upstreamSrc = fetchFromGitHub {
    owner = "juicesharp";
    repo = "rpiv-mono";
    rev = "v${version}";
    hash = "sha256-L+c/p6yhTDznxszJ8kkAxxGEWfizf5rFbXmiIGClWKg=";
  };

  src =
    if builtins.pathExists ./package-lock.patch then
      applyPatches {
        name = "rpiv-mono-${version}-source";
        src = upstreamSrc;
        patches = [ ./package-lock.patch ];
      }
    else
      upstreamSrc;
in
{
  inherit version src;

  npmDepsHash = "sha256-GkzroNmbhTMSs1hCX4QGNbFWlgvv/Q+RNv1F1S8cK4k=";
  npmDepsFetcherVersion = 2;
}