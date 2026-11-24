{
  lib,
  stdenvNoCC,
  fetchFromGitHub,
}:
let
  version = "0.2.5";
in
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "pi-ralph-wiggum";
  inherit version;

  # Upstream ships several Pi extensions in one repo and tags each package
  # separately (`pi-ralph-wiggum/vX.Y.Z`), so the source is the whole repo while
  # only this subdirectory is installed.
  src = fetchFromGitHub {
    owner = "tmustier";
    repo = "pi-extensions";
    rev = "pi-ralph-wiggum/v${version}";
    hash = "sha256-tVAS5gD9q3T0Qu0j/jGjErvfmb43+yB5BLY1TETZs6I=";
  };

  dontBuild = true;

  installPhase = ''
    runHook preInstall

    packageDir="$out/lib/node_modules/pi-ralph-wiggum"
    mkdir -p "$packageDir"
    cp pi-ralph-wiggum/index.ts pi-ralph-wiggum/package.json "$packageDir/"

    # Optional docs/license files, preferring the package's own copy and falling
    # back to the repo root so tag layout changes don't break the build.
    for f in README.md LICENSE CHANGELOG.md UPDATE_NOTES.md; do
      if [ -f "pi-ralph-wiggum/$f" ]; then
        cp "pi-ralph-wiggum/$f" "$packageDir/"
      elif [ -f "$f" ]; then
        cp "$f" "$packageDir/"
      fi
    done

    # Upstream declares the skill as ./SKILL.md in the package root. Project it
    # into the conventional skills/<name>/ layout so `--skill` gets a directory
    # containing SKILL.md rather than a standalone markdown file.
    mkdir -p "$packageDir/skills/pi-ralph-wiggum"
    cp pi-ralph-wiggum/SKILL.md "$packageDir/skills/pi-ralph-wiggum/SKILL.md"

    runHook postInstall
  '';

  passthru = {
    packageDir = "${finalAttrs.finalPackage}/lib/node_modules/pi-ralph-wiggum";
    extensions = [
      "${finalAttrs.finalPackage}/lib/node_modules/pi-ralph-wiggum/index.ts"
    ];
    skills = [ "${finalAttrs.finalPackage}/lib/node_modules/pi-ralph-wiggum/skills" ];
  };

  meta = {
    description = "Pi extension for long-running iterative development loops (Ralph Wiggum)";
    homepage = "https://github.com/tmustier/pi-extensions/tree/main/pi-ralph-wiggum";
    license = lib.licenses.mit;
    platforms = lib.platforms.all;
  };
})
