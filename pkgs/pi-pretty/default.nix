{
  lib,
  buildNpmPackage,
  fetchFromGitHub,
}:
let
  version = "0.9.0";
  src = fetchFromGitHub {
    owner = "heyhuynhgiabuu";
    repo = "pi-pretty";
    rev = "v${version}";
    hash = "sha256-/7M8yp3wUrd/CdNoYAznQvGUNuiozoYqAnq15D23UU4=";
  };
in
buildNpmPackage (finalAttrs: {
  pname = "pi-pretty";
  inherit version src;

  npmDepsHash = "sha256-FjlaTp7xi4deQtoppedrEzzYFI16IwKREu5kooLv83Y=";

  # vitest needs devDependencies, which the install hook prunes afterwards.
  doCheck = true;
  checkPhase = ''
    runHook preCheck
    npm test
    runHook postCheck
  '';

  postInstall = ''
    # pi.nix profiles probe lib/node_modules/<pname>, while runtime imports use
    # the scoped package name the npm install hook writes.
    ln -s @heyhuynhgiabuu/pi-pretty "$out/lib/node_modules/pi-pretty"
  '';

  passthru = {
    packageDir = "${finalAttrs.finalPackage}/lib/node_modules/@heyhuynhgiabuu/pi-pretty";
    extensions = [
      "${finalAttrs.finalPackage}/lib/node_modules/@heyhuynhgiabuu/pi-pretty/src/index.ts"
    ];
  };

  meta = {
    description = "Pretty terminal output for pi - syntax-highlighted reads, colored bash, tree-view ls, grouped grep";
    homepage = "https://github.com/heyhuynhgiabuu/pi-pretty";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
  };
})
