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
  rpivDependencies ? [ ],
}:
stdenvNoCC.mkDerivation (finalAttrs: {
  inherit pname version;

  dontUnpack = true;

  installPhase = ''
    runHook preInstall

    packageDir="$out/lib/node_modules/${pname}"
    packageNodeModules="$packageDir/node_modules"
    scopedDir="$out/lib/node_modules/@juicesharp"

    mkdir -p "$packageDir" "$packageNodeModules/@juicesharp" "$scopedDir"

    # Primary package.
    cp -r "${src}/packages/${pname}/." "$packageDir/"

    # Preserve the scoped top-level representation as well.
    ln -s ../${pname} "$scopedDir/${pname}"

    # Install monorepo dependencies where Node will find them when this
    # package is projected into ~/.pi/agent/extensions/${pname}.
    ${lib.concatMapStringsSep "\n" (
      dependency: ''
        dependencyDir="$packageNodeModules/@juicesharp/${dependency}"

        mkdir -p "$dependencyDir"
        cp -r "${src}/packages/${dependency}/." "$dependencyDir/"
      ''
    ) rpivDependencies}

    runHook postInstall
  '';

  passthru = {
    packageDir = "${finalAttrs.finalPackage}/lib/node_modules/${pname}";
    extensions = [ "${finalAttrs.finalPackage}/lib/node_modules/${pname}/index.ts" ];
  };

  meta = {
    inherit description homepage;
    license = lib.licenses.mit;
    platforms = lib.platforms.all;
  };
})
