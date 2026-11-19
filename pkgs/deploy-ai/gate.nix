# The login shell of `deployer`: the only thing sshd may run for the build VM's key.
#
# sshd hands a requested command to the login shell as `-c "<command>"` and exports the same string
# as SSH_ORIGINAL_COMMAND, so the command is read from either: a plain login shell today, a
# `ForceCommand` later.  An interactive session arrives with neither set to a `deploy-ai` call, so
# it is refused.
#
# The command becomes argv and is passed to sudo without being re-evaluated by a shell, so a `;`
# cannot start a second command.  Metacharacters are refused anyway, so the only strings that reach
# deploy-ai are ones deploy-ai's own parser accepts.  This is a guardrail against mistakes, not a
# sandbox: what it protects is that `deployer` can run deploy-ai and nothing else.
# The setuid copy of sudo, not the store path.  sshd runs this shell with its own PATH, where `sudo`
# resolves to the read-only store copy (`-r-xr-xr-x`), and sudo refuses to run unless it is root-owned
# *with* the setuid bit: `sudo must be owned by uid 0 and have the setuid bit set`.  NixOS puts that
# bit on the copy under `security.wrapperDir`, which the module passes explicitly.
{
  pkgs,
  lib,
  sudoPath ? "/run/wrappers/bin/sudo",
  name ? "deploy-ai-gate",
}:
pkgs.writeShellScriptBin name ''
  cmd=''${SSH_ORIGINAL_COMMAND:-''${2:-}}

  case "$cmd" in
    deploy-ai | 'deploy-ai '*) ;;
    *)
      echo "deploy-ai gate: only 'deploy-ai ...' is accepted here." >&2
      echo "deploy-ai gate: try 'deploy-ai --status', 'deploy-ai --repo <url> --list'," >&2
      echo "deploy-ai gate:   or 'deploy-ai --submit' with a patch series on stdin." >&2
      exit 1
      ;;
  esac

  for bad in ';' '&' '|' '<' '>' '$' '`' '*'; do
    case "$cmd" in
      *"$bad"*)
        echo "deploy-ai gate: refusing a command containing '$bad'." >&2
        exit 1
        ;;
    esac
  done

  # Field splitting only: the command is already known to be a deploy-ai invocation with no
  # metacharacters, and globbing is off so a `*` in an argument could never match a file.
  set -f
  set -- ''${cmd}
  set +f
  shift

  # sudo comes from the setuid wrapper directory, which only exists when sudo is enabled; saying so
  # here beats sudo's `must be owned by uid 0 and have the setuid bit set`.
  SUDO=${lib.escapeShellArg sudoPath}
  if [ ! -x "$SUDO" ]; then
    echo "deploy-ai gate: $SUDO is not executable, so nothing can be deployed." >&2
    echo "deploy-ai gate: ai needs security.sudo.enable for the setuid copy of sudo to exist." >&2
    exit 1
  fi

  exec "$SUDO" -n /run/current-system/sw/bin/deploy-ai "$@"
''
