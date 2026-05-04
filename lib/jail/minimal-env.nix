{
  combinators,
  lib,
  ...
}:
let
  inherit (combinators)
    add-runtime
    compose
    escape
    ;
in
{
  sig = "String -> [ String ] -> Permission";
  doc = ''
    Clears the jailed process environment and recreates a small allowlisted
    environment with an isolated HOME inside the jail.

    The current shell's `PATH` is forwarded as-is, so pair this with a PATH
    sanitizing combinator such as `safe-path-from-var-resolved` first.
  '';
  impl =
    home: forwarded:
    assert lib.isList forwarded;
    compose [
      (add-runtime ''
        PI_JAIL_HOME=${escape home}
        PI_JAIL_XDG_CONFIG_HOME="$PI_JAIL_HOME/.config"
        PI_JAIL_XDG_CACHE_HOME="$PI_JAIL_HOME/.cache"
        PI_JAIL_XDG_STATE_HOME="$PI_JAIL_HOME/.local/state"

        addPiMinimalEnvVar() {
          local name value
          name="$1"
          value="$2"
          RUNTIME_ARGS+=(--setenv "$name" "$value")
          return 0
        }

        tryAddPiMinimalEnvVar() {
          local name
          name="$1"

          if [ -n "''${!name+x}" ]; then
            addPiMinimalEnvVar "$name" "''${!name}"
          fi
          return 0
        }

        RUNTIME_ARGS+=(
          --dir "$PI_JAIL_HOME"
          --dir "$PI_JAIL_XDG_CONFIG_HOME"
          --dir "$PI_JAIL_XDG_CACHE_HOME"
          --dir "$PI_JAIL_HOME/.local"
          --dir "$PI_JAIL_XDG_STATE_HOME"
          --clearenv
        )

        addPiMinimalEnvVar HOME "$PI_JAIL_HOME"
        addPiMinimalEnvVar XDG_CONFIG_HOME "$PI_JAIL_XDG_CONFIG_HOME"
        addPiMinimalEnvVar XDG_CACHE_HOME "$PI_JAIL_XDG_CACHE_HOME"
        addPiMinimalEnvVar XDG_STATE_HOME "$PI_JAIL_XDG_STATE_HOME"
        addPiMinimalEnvVar GIT_TERMINAL_PROMPT 0
        addPiMinimalEnvVar GIT_CONFIG_NOSYSTEM 1

        if [ -n "''${PATH-}" ]; then
          addPiMinimalEnvVar PATH "$PATH"
        fi

        if [ -n "''${LANG-}" ]; then
          addPiMinimalEnvVar LANG "$LANG"
        fi

        if [ -n "''${TERM-}" ]; then
          addPiMinimalEnvVar TERM "$TERM"
        fi

        if [ -n "''${USER-}" ]; then
          addPiMinimalEnvVar USER "$USER"
          addPiMinimalEnvVar LOGNAME "$USER"
        else
          addPiMinimalEnvVar USER pi
          addPiMinimalEnvVar LOGNAME pi
        fi

        if [ -n "''${PWD-}" ]; then
          addPiMinimalEnvVar PWD "$PWD"
        fi
      '')
      (add-runtime ''
        PI_MINIMAL_ENV_FORWARDED=(
${lib.concatMapStrings (name: "          ${escape name}\n") forwarded}        )

        for PI_MINIMAL_ENV_NAME in "''${PI_MINIMAL_ENV_FORWARDED[@]}"; do
          tryAddPiMinimalEnvVar "$PI_MINIMAL_ENV_NAME"
        done
      '')
    ];
}
