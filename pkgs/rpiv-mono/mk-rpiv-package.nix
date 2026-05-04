{
  lib,
  stdenvNoCC,
}:
{
  pname,
  version,
  src,
  description,
  homepage,
}:
stdenvNoCC.mkDerivation {
  inherit pname version;

  dontUnpack = true;

  installPhase = ''
    runHook preInstall

    # pi-agent.wrap probes lib/node_modules/${pname} first, but runtime imports use the scoped name.
    packageDir="$out/lib/node_modules/${pname}"
    scopedDir="$out/lib/node_modules/@juicesharp"
    mkdir -p "$packageDir" "$scopedDir"
    cp -r "${src}/packages/${pname}/." "$packageDir/"
    ln -s ../${pname} "$scopedDir/${pname}"

    runHook postInstall
  '';

  passthru = {
    packageDir = "${placeholder "out"}/lib/node_modules/@juicesharp/${pname}";
  };

  meta = {
    inherit description homepage;
    license = lib.licenses.mit;
    platforms = lib.platforms.all;
  };
}
