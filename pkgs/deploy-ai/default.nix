{ lib, pkgs }:
# repo-local logic, no upstream counterpart, so no update.sh.  The script is inlined verbatim.
pkgs.writeShellScriptBin "deploy-ai" (builtins.readFile ./deploy-ai.sh)
// {
  # The scope guard needs root on a live host, so its allowlist logic is tested here against
  # synthetic trees instead.
  passthru.tests.scope = pkgs.runCommand "deploy-ai-scope-test" { } ''
    mkdir -p "$out"
    cp ${./deploy-ai.sh} deploy-ai.sh
    cp ${./test-scope.sh} test-scope.sh
    bash ./test-scope.sh > "$out/result.log"
  '';
}
