{ lib, pkgs }:
# repo-local logic, no upstream counterpart, so no update.sh.
#
# The tool is a single stdlib-only module, so there is nothing to fetch and nothing to build: a
# wrapper that names the interpreter and the commands it shells out to.  Those commands are why
# `deploy-ai` lives in `pkgs/` rather than being inlined as a shell script — the VM-side build,
# the closure copy, and the health probes all need real binaries in its PATH, and the gate's
# forced command runs it with whatever PATH sshd hands over.
let
  runtimePath = lib.makeBinPath [
    pkgs.git
    pkgs.nix
    pkgs.openssh
    pkgs.curl
    pkgs.gnutar
    pkgs.systemd
  ];
in
pkgs.writeShellScriptBin "deploy-ai" ''
  # ssh, tar, curl, and systemctl all come from here; a login shell's PATH under the gate has
  # none of them.
  export PATH=${runtimePath}:"$PATH"
  exec ${lib.getExe pkgs.python3} ${./deploy-ai.py} "$@"
''
// {
  # The scope guard needs root on a live host, so its logic is tested here against synthetic trees
  # instead: temp state dir, synthetic baseline, and every path passed through the environment.
  # It shells out to git and tar, so the test needs both in its PATH.
  passthru.tests.scope =
    pkgs.runCommand "deploy-ai-scope-test"
      {
        nativeBuildInputs = [
          pkgs.python3
          pkgs.git
          pkgs.gnutar
        ];
      }
      ''
        mkdir -p "$out"
        cp ${./deploy-ai.py} deploy-ai.py
        cp ${./test-deploy-ai.py} test-deploy-ai.py
        python3 ./test-deploy-ai.py > "$out/result.log" 2>&1
      '';
}
