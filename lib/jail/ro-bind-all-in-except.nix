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
    include-once
    ;
in
{
  sig = "String -> String -> [ String ] -> Permission";
  doc = ''
    Binds every file and directory directly inside the specified host
    directory into the jail as read-only, except for entries listed in
    `except`.

    Exclusions may be bare entry names like `"tmp"` or paths like `"/tmp"`.
    For runtime-dependent paths such as `$HOME`, pass `noescape` so the shell
    expands them at runtime.

    Example:
    ```nix
    ro-bind-all-in-except "/etc" "/etc" [
      "ssh"
      "shadow"
    ]
    ```
  '';
  impl =
    from: to: except:
    assert lib.isList except;
    let
      helper = include-once "ro-bind-all-in-except-helpers" (add-runtime ''
        if ! declare -p JAIL_RO_BIND_ALL_IN_EXCEPT_DIRS_SEEN >/dev/null 2>&1; then
          declare -g -A JAIL_RO_BIND_ALL_IN_EXCEPT_DIRS_SEEN=()
        fi

        addRoBindAllInExceptDir() {
          local path
          path="$1"

          if [ "$path" = / ] || [ "$path" = . ]; then
            return 0
          fi

          if [ -n "''${JAIL_RO_BIND_ALL_IN_EXCEPT_DIRS_SEEN[$path]-}" ]; then
            return 0
          fi
          JAIL_RO_BIND_ALL_IN_EXCEPT_DIRS_SEEN[$path]=1
          RUNTIME_ARGS+=(--dir "$path")
          return 0
        }

        addRoBindAllInExceptParentDirs() {
          local path parent
          local -a parents
          path="$1"
          parent="$(dirname "$path")"
          parents=()

          while [ "$parent" != / ] && [ "$parent" != . ]; do
            parents+=("$parent")
            parent="$(dirname "$parent")"
          done

          for ((i = ''${#parents[@]} - 1; i >= 0; i--)); do
            addRoBindAllInExceptDir "''${parents[$i]}"
          done
          return 0
        }
      '');
      excludedArrayEntries = lib.concatMapStrings (name: ''
          ${escape name}
      '') except;
      excludedBlock = lib.optionalString (except != [ ]) ''
        JAIL_RO_BIND_ALL_IN_EXCEPT_SKIP=0
        for JAIL_RO_BIND_ALL_IN_EXCEPT_EXCLUDED_ENTRY in "''${JAIL_RO_BIND_ALL_IN_EXCEPT_EXCLUDED[@]}"; do
          JAIL_RO_BIND_ALL_IN_EXCEPT_EXCLUDED_NAME="$(basename -- "$JAIL_RO_BIND_ALL_IN_EXCEPT_EXCLUDED_ENTRY")"

          if
            [ "$JAIL_RO_BIND_ALL_IN_EXCEPT_EXCLUDED_ENTRY" = "$JAIL_RO_BIND_ALL_IN_EXCEPT_NAME" ] ||
            [ "$JAIL_RO_BIND_ALL_IN_EXCEPT_EXCLUDED_NAME" = "$JAIL_RO_BIND_ALL_IN_EXCEPT_NAME" ] ||
            [ "$JAIL_RO_BIND_ALL_IN_EXCEPT_EXCLUDED_ENTRY" = "$JAIL_RO_BIND_ALL_IN_EXCEPT_ENTRY" ] ||
            [[ "$JAIL_RO_BIND_ALL_IN_EXCEPT_EXCLUDED_ENTRY" == "$JAIL_RO_BIND_ALL_IN_EXCEPT_ENTRY"/* ]]
          then
            JAIL_RO_BIND_ALL_IN_EXCEPT_SKIP=1
            break
          fi
        done

        if [ "$JAIL_RO_BIND_ALL_IN_EXCEPT_SKIP" -eq 1 ]; then
          continue
        fi
      '';
    in
    compose [
      helper
      (add-runtime ''
        JAIL_RO_BIND_ALL_IN_EXCEPT_FROM=${escape from}
        JAIL_RO_BIND_ALL_IN_EXCEPT_TO=${escape to}

        if ! [ -d "$JAIL_RO_BIND_ALL_IN_EXCEPT_FROM" ]; then
          echo "jail.nix: ro-bind-all-in-except expected a directory: $JAIL_RO_BIND_ALL_IN_EXCEPT_FROM" >&2
          exit 1
        fi

        addRoBindAllInExceptParentDirs "$JAIL_RO_BIND_ALL_IN_EXCEPT_TO"
        addRoBindAllInExceptDir "$JAIL_RO_BIND_ALL_IN_EXCEPT_TO"

        JAIL_RO_BIND_ALL_IN_EXCEPT_DOTGLOB=0
        JAIL_RO_BIND_ALL_IN_EXCEPT_NULLGLOB=0
        shopt -q dotglob && JAIL_RO_BIND_ALL_IN_EXCEPT_DOTGLOB=1
        shopt -q nullglob && JAIL_RO_BIND_ALL_IN_EXCEPT_NULLGLOB=1
        shopt -s dotglob nullglob

        JAIL_RO_BIND_ALL_IN_EXCEPT_EXCLUDED=(
      ${excludedArrayEntries}  )

        for JAIL_RO_BIND_ALL_IN_EXCEPT_ENTRY in "$JAIL_RO_BIND_ALL_IN_EXCEPT_FROM"/*; do
          JAIL_RO_BIND_ALL_IN_EXCEPT_NAME="$(basename "$JAIL_RO_BIND_ALL_IN_EXCEPT_ENTRY")"
      ${excludedBlock}
          RUNTIME_ARGS+=(
            --ro-bind
            "$JAIL_RO_BIND_ALL_IN_EXCEPT_ENTRY"
            "$JAIL_RO_BIND_ALL_IN_EXCEPT_TO/$JAIL_RO_BIND_ALL_IN_EXCEPT_NAME"
          )
        done

        if [ "$JAIL_RO_BIND_ALL_IN_EXCEPT_DOTGLOB" -eq 0 ]; then
          shopt -u dotglob
        fi
        if [ "$JAIL_RO_BIND_ALL_IN_EXCEPT_NULLGLOB" -eq 0 ]; then
          shopt -u nullglob
        fi
      '')
    ];
}
