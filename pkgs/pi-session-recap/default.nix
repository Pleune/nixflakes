{
  lib,
  stdenvNoCC,
  fetchFromGitHub,
}:
let
  version = "0.6.1";
in
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "pi-session-recap";
  inherit version;

  # Same monorepo as pi-ralph-wiggum: per-package tags, whole-repo source.
  src = fetchFromGitHub {
    owner = "tmustier";
    repo = "pi-extensions";
    rev = "session-recap/v${version}";
    hash = "sha256-h+DfNiHN9SFKDuRSryc1G8wVD4wH7799MGI6UWOWwXE=";
  };

  dontBuild = true;

  installPhase = ''
    runHook preInstall

    packageDir="$out/lib/node_modules/pi-session-recap"
    mkdir -p "$packageDir"
    cp session-recap/index.ts session-recap/package.json "$packageDir/"

    # Optional docs/license files, preferring the package's own copy and falling
    # back to the repo root so tag layout changes don't break the build. `assets/`
    # holds README screenshots only, so it is not installed.
    for f in README.md LICENSE CHANGELOG.md UPDATE_NOTES.md; do
      if [ -f "session-recap/$f" ]; then
        cp "session-recap/$f" "$packageDir/"
      elif [ -f "$f" ]; then
        cp "$f" "$packageDir/"
      fi
    done

    runHook postInstall
  '';

  passthru = {
    packageDir = "${finalAttrs.finalPackage}/lib/node_modules/pi-session-recap";
    extensions = [
      "${finalAttrs.finalPackage}/lib/node_modules/pi-session-recap/index.ts"
    ];
  };

  meta = {
    description = "Pi extension that shows a while-you-were-away recap when returning to a session";
    homepage = "https://github.com/tmustier/pi-extensions/tree/main/session-recap";
    license = lib.licenses.mit;
    platforms = lib.platforms.all;
  };
})
