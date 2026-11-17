{ lib, pkgs }:
# repo-local logic, no upstream counterpart, so no update.sh.
pkgs.writeShellScriptBin "deploy-ai" (builtins.readFile ./deploy-ai.sh)
// {
  # The scope guard is the part worth testing: it runs as root on a real host, so its allowlist
  # logic gets checked here against synthetic trees instead of against a live switch.
  passthru.tests.scope = pkgs.runCommand "deploy-ai-scope-test" { } ''
    mkdir -p "$out"
    cp ${./deploy-ai.sh} deploy-ai.sh
    cp ${./test-scope.sh} test-scope.sh
    bash ./test-scope.sh > "$out/result.log"
  '';
}
