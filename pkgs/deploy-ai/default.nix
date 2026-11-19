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
  # The gate has to name sudo's setuid copy, which lives wherever NixOS puts setuid wrappers.  The
  # default is that path; the module passes `config.security.wrapperDir` so the gate follows the host
  # rather than a guess.
  gateFor = sudoPath: pkgs.callPackage ./gate.nix { inherit sudoPath; };
in
pkgs.writeShellScriptBin "deploy-ai" ''
  # ssh, tar, curl, and systemctl all come from here; a login shell's PATH under the gate has
  # none of them.
  export PATH=${runtimePath}:"$PATH"
  exec ${lib.getExe pkgs.python3} ${./deploy-ai.py} "$@"
''
// {
  # The login shell of `deployer`, shipped in the same package so the gate and the tool it guards
  # cannot drift apart.  The module wires it into /run/current-system/sw and /etc/passwd, and builds
  # its own with `gateFor` to name the host's setuid sudo.
  gateFor = gateFor;
  gate = gateFor "/run/wrappers/bin/sudo";

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

  # The gate is a shell script whose whole job is how it reads sshd's argv, so it is tested against
  # a stub standing in for sudo rather than against a live sshd.
  passthru.tests.gate = pkgs.callPackage ./test-gate.nix { };
}
