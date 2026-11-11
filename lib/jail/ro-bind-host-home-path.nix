{
  combinators,
  lib,
  ...
}:
let
  inherit (combinators)
    add-runtime
    escape
    ;
in
{
  sig = "String -> String -> Permission";
  doc = ''
    Binds a path inside the host home directory into the jail as read-only,
    but only when the host path exists, so jail setup never fails on hosts
    without it.

    `from` is resolved relative to `PI_HOST_HOME`, so use this after
    `capture-host-home`. `to` is resolved relative to `PI_JAIL_HOME`, so use
    this after `minimal-env`. Both may be files or directories.

    Example:
    ```nix
    ro-bind-host-home-path ".config/git" ".config/git"
    ```
  '';
  impl =
    from: to:
    assert lib.isString from;
    assert lib.isString to;
    add-runtime ''
      piHostHomePath="${escape from}"
      piJailHomePath="${escape to}"

      if [ -n "''${PI_HOST_HOME-}" ] && [ -n "''${PI_JAIL_HOME-}" ]; then
        piHostHomeSource="$PI_HOST_HOME/$piHostHomePath"
        piHostHomeTarget="$PI_JAIL_HOME/$piJailHomePath"

        if [ -e "$piHostHomeSource" ]; then
          mkdir -p "$(dirname "$piHostHomeTarget")"
          RUNTIME_ARGS+=(--ro-bind "$piHostHomeSource" "$piHostHomeTarget")
        fi
      fi
    '';
}
