{
  fetchFromGitHub,
  applyPatches,
}:
let
  version = "2.7.1";

  upstreamSrc = fetchFromGitHub {
    owner = "juicesharp";
    repo = "rpiv-mono";
    rev = "v${version}";
    hash = "sha256-fS5+nOwJiQ7LOIGh/PE3R1+U6SPQEouFVxVnjYz3PVc=";
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

  npmDepsHash = "sha256-MxD7JLe5hqu9IGVcohrqCor/u9/ny8t6bwjJP25aPW4=";
  npmDepsFetcherVersion = 2;
}