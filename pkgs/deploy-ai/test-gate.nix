# The gate's argv contract, checked against a stub standing in for sudo.
#
# sshd runs a login shell as `-c "<command>"`, so the command arrives in `$2` and as
# SSH_ORIGINAL_COMMAND -- never in `$1`, which is what an earlier gate read, making it refuse every
# command including valid ones.  These cases pin the extraction, the split into argv, and the
# commands that must still be refused.
{
  pkgs,
  lib,
  gateModule ? ./gate.nix,
}:
let
  # Stands in for `sudo -n /run/current-system/sw/bin/deploy-ai ...`, recording what it was handed.
  stub = pkgs.writeShellScriptBin "stub-sudo" ''
    printf '%s\n' "$@" > "$GATE_TEST_LOG"
  '';
  gate = pkgs.callPackage gateModule {
    sudoPath = lib.getExe stub;
  };
in
pkgs.runCommand "deploy-ai-gate-test"
  { nativeBuildInputs = [ pkgs.bash ]; }
  ''
    mkdir -p "$out"
    gate=${gate}/bin/deploy-ai-gate
    log="$PWD/argv.log"

    bash -n "$gate"

    pass=0
    fail=0
    rc=0
    err=""

    run() {
      : > "$log"
      rc=0
      # Both streams: the gate answers refusals on stderr, and deploy-ai's own output would be
      # stdout, and neither should reach the test's own report.
      err=$(env GATE_TEST_LOG="$log" "$@" 2>&1) || rc=$?
    }

    expect_argv() {
      local label=$1 expected=$2
      if [ "$rc" -ne 0 ]; then
        echo "FAIL - $label: gate exited $rc: $err"
        fail=$((fail + 1))
        return
      fi
      if [ "$(cat "$log")" = "$(printf '%s' "$expected")" ]; then
        echo "ok   - $label"
        pass=$((pass + 1))
      else
        echo "FAIL - $label: sudo received [$(tr '\n' '|' < "$log")], wanted [$(printf '%s' "$expected" | tr '\n' '|')]"
        fail=$((fail + 1))
      fi
    }

    expect_refused() {
      local label=$1 needle=$2
      if [ "$rc" -ne 1 ]; then
        echo "FAIL - $label: gate exited $rc, expected 1"
        fail=$((fail + 1))
        return
      fi
      case "$err" in
        *"$needle"*)
          if [ -s "$log" ]; then
            echo "FAIL - $label: refused but still reached sudo: [$(tr '\n' '|' < "$log")]"
            fail=$((fail + 1))
          else
            echo "ok   - $label"
            pass=$((pass + 1))
          fi
          ;;
        *)
          echo "FAIL - $label: exit $rc without the expected message, said: $err"
          fail=$((fail + 1))
          ;;
      esac
    }

    target=/run/current-system/sw/bin/deploy-ai

    # sshd's login-shell wiring: `-c <command>`.
    run "$gate" -c 'deploy-ai --status'
    expect_argv "login shell -c reaches sudo with the flag" "-n
$target
--status"

    run "$gate" -c 'deploy-ai --repo ssh://builder@127.0.0.1:2224/home/builder/nixflakes --list'
    expect_argv "one command string is split into argv" "-n
$target
--repo
ssh://builder@127.0.0.1:2224/home/builder/nixflakes
--list"

    run "$gate" -c 'deploy-ai --submit'
    expect_argv "--submit is passed through, stdin left to sshd" "-n
$target
--submit"

    run "$gate" -c 'deploy-ai'
    expect_argv "a bare deploy-ai runs, and prints its usage" "-n
$target"

    # A ForceCommand wiring: the client command lives in the environment, and wins over $2.
    run env SSH_ORIGINAL_COMMAND='deploy-ai --vet' "$gate" -c 'ls /'
    expect_argv "SSH_ORIGINAL_COMMAND beats -c" "-n
$target
--vet"

    run env SSH_ORIGINAL_COMMAND='deploy-ai --status' "$gate"
    expect_argv "SSH_ORIGINAL_COMMAND alone" "-n
$target
--status"

    # What must never reach sudo.
    run "$gate" -c 'ls /'
    expect_refused "an arbitrary command is refused" "only 'deploy-ai ...' is accepted here"

    run "$gate"
    expect_refused "an interactive session is refused" "only 'deploy-ai ...' is accepted here"

    # sshd runs a tty session as `-c <the login shell>`, so the gate's own path arrives this way.
    run "$gate" -c '/run/current-system/sw/bin/deploy-ai-gate'
    expect_refused "the login shell itself is refused" "only 'deploy-ai ...' is accepted here"

    run "$gate" -c 'deploy-ai --status; echo pwned'
    expect_refused "a chained command is refused" "refusing a command containing ';'"

    # `deploy-ai;` is not a deploy-ai invocation, so it is refused before the metacharacter scan.
    run "$gate" -c 'deploy-ai; id'
    expect_refused "a chained command after a bare deploy-ai is refused" "only 'deploy-ai ...' is accepted here"

    run "$gate" -c 'deploy-ai --ref main && reboot'
    expect_refused "a background/chained command is refused" "refusing a command containing '&'"

    run "$gate" -c 'deploy-ai --repo $(evil)'
    expect_refused "command substitution is refused" "refusing a command containing '$'"

    run "$gate" -c 'deploy-ai --ref main | tee /dev/null'
    expect_refused "a pipe is refused" "refusing a command containing '|'"

    echo "gate: $pass passed, $fail failed"
    [ "$fail" -eq 0 ]
  ''
