{
  lib,
  pkgs,
  jail-nix,
  callPackage,
  writeShellScriptBin,
}:
let
  jail = (import ../../lib/jail { inherit jail-nix pkgs; }).extend;
  permissions = import ../../config/agent-sandbox/permissions.nix { inherit pkgs; };
  entry = writeShellScriptBin "agent-sandbox-exec" ''
    exec -- "$@"
  '';
  jailed = jail "agent-sandbox-run" entry permissions;
  sandbox =
    (writeShellScriptBin "agent-sandbox" ''
      if [ "$#" -eq 0 ]; then
        echo 'Usage: agent-sandbox COMMAND [ARG...]' >&2
        exit 64
      fi
      exec ${lib.getExe jailed} "$@"
    '').overrideAttrs
      (_: {
        passthru = {
          wrap = callPackage ./wrap-package.nix { agent-sandbox = sandbox; };
          tests = import ./tests.nix {
            inherit pkgs;
            agent-sandbox = sandbox;
          };
        };
        meta = {
          description = "Run commands in the shared agent development sandbox";
          homepage = "https://git.pleunetowne.com/mitchpleune/nixflakes";
          license = lib.licenses.mit;
          platforms = lib.platforms.linux;
          mainProgram = "agent-sandbox";
        };
      });
in
sandbox
