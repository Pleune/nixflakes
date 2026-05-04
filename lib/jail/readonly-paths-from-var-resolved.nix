{
  combinators,
  lib,
  pkgs,
  ...
}:
let
  inherit (combinators)
    add-runtime
    include-once
    ;
in
{
  sig = "String -> String -> Permission";
  doc = ''
    This binds multiple paths as read-only specified by a single runtime
    environment variable.

    Unlike the upstream `readonly-paths-from-var`, this also follows symlinks
    in the bound directories up to 10 levels and binds the paths needed to
    execute those entries.
  '';
  impl =
    var: separator:
    assert lib.isValidPosixName var;
    include-once "readonly-paths-from-var-resolved-${var}" (add-runtime ''
      declare -A JAIL_RO_BINDS_SEEN=()
      declare -A JAIL_DIRS_SEEN=()
      declare -A JAIL_EXISTING_BWRAP_PATHS_SEEN=()
      declare -A JAIL_COVERING_BWRAP_PATHS_SEEN=()
      declare -A JAIL_QUEUED_BIND_SRCS=()

      normalizePath() {
        local path
        path="$1"

        if [ -z "$path" ]; then
          return 0
        fi

        path="$(printf '%s\n' "$path" | tr -s /)"

        if [ "$path" != / ]; then
          path="''${path%/}"
        fi

        printf '%s\n' "$path"
        return 0
      }

      rememberExistingBwrapPath() {
        local path key
        path="$(normalizePath "$1")"

        if [ -z "$path" ]; then
          return 0
        fi

        key="path $path"
        JAIL_EXISTING_BWRAP_PATHS_SEEN[$key]=1
        return 0
      }

      rememberCoveringBwrapPath() {
        local path key
        path="$(normalizePath "$1")"

        if [ -z "$path" ]; then
          return 0
        fi

        key="path $path"
        JAIL_COVERING_BWRAP_PATHS_SEEN[$key]=1
        return 0
      }

      existingBwrapPathExists() {
        local path key
        path="$(normalizePath "$1")"
        key="path $path"
        [ -n "''${JAIL_EXISTING_BWRAP_PATHS_SEEN[$key]-}" ]
      }

      coveringBwrapPathExists() {
        local path existing key
        path="$(normalizePath "$1")"
        key="path $path"

        if [ -n "''${JAIL_COVERING_BWRAP_PATHS_SEEN[$key]-}" ]; then
          return 0
        fi

        for key in "''${!JAIL_COVERING_BWRAP_PATHS_SEEN[@]}"; do
          existing="''${key#path }"
          case "$path" in
            "$existing"/*)
              return 0
            ;;
          esac
        done

        return 1
      }

      rememberExistingRuntimeArgs() {
        local i arg path
        i=0
        while [ "$i" -lt "''${#RUNTIME_ARGS[@]}" ]; do
          arg="''${RUNTIME_ARGS[$i]}"
          case "$arg" in
            --bind|--bind-try|--dev-bind|--dev-bind-try|--ro-bind|--ro-bind-try)
              if [ $((i + 2)) -lt "''${#RUNTIME_ARGS[@]}" ]; then
                path="''${RUNTIME_ARGS[$((i + 2))]}"
                rememberExistingBwrapPath "$path"
                if [ -d "$path" ]; then
                  rememberCoveringBwrapPath "$path"
                fi
              fi
              i=$((i + 3))
              continue
            ;;
            --dev|--mqueue|--proc|--tmpfs)
              if [ $((i + 1)) -lt "''${#RUNTIME_ARGS[@]}" ]; then
                path="''${RUNTIME_ARGS[$((i + 1))]}"
                rememberExistingBwrapPath "$path"
              fi
              i=$((i + 2))
              continue
            ;;
            --dir)
              if [ $((i + 1)) -lt "''${#RUNTIME_ARGS[@]}" ]; then
                rememberExistingBwrapPath "''${RUNTIME_ARGS[$((i + 1))]}"
              fi
              i=$((i + 2))
              continue
            ;;
            --symlink)
              if [ $((i + 2)) -lt "''${#RUNTIME_ARGS[@]}" ]; then
                rememberExistingBwrapPath "''${RUNTIME_ARGS[$((i + 2))]}"
              fi
              i=$((i + 3))
              continue
            ;;
          esac
          i=$((i + 1))
        done
        return 0
      }

      rememberExistingBwrapPaths() {
        rememberExistingBwrapPath /proc
        rememberExistingBwrapPath /dev
        rememberExistingBwrapPath /tmp
        rememberExistingBwrapPath "$HOME"
        rememberExistingBwrapPath /bin/sh
        rememberExistingBwrapPath /etc/passwd
        rememberExistingBwrapPath /etc/group
        rememberExistingRuntimeArgs
        return 0
      }

      addDir() {
        local path key
        path="$1"
        key="$path"

        if [ -n "''${JAIL_DIRS_SEEN[$key]-}" ]; then
          if [ "''${JAIL_DEBUG_PATHS-}" = 1 ]; then
            echo "readonly-paths-from-var-resolved: skip queued dir $path" >&2
          fi
          return 0
        fi

        if existingBwrapPathExists "$path" || coveringBwrapPathExists "$path"; then
          if [ "''${JAIL_DEBUG_PATHS-}" = 1 ]; then
            echo "readonly-paths-from-var-resolved: skip existing dir $path" >&2
          fi
          return 0
        fi

        JAIL_DIRS_SEEN[$key]=1
        if [ "''${JAIL_DEBUG_PATHS-}" = 1 ]; then
          echo "readonly-paths-from-var-resolved: queue dir $path" >&2
        fi
        return 0
      }

      addParentDirs() {
        local path parent i
        local -a parents
        path="$1"
        parent="$(dirname "$path")"
        parents=()

        while [ "$parent" != / ] && [ "$parent" != . ]; do
          if [ "$parent" = "$HOME" ]; then
            break
          fi
          parents+=("$parent")
          parent="$(dirname "$parent")"
        done

        for ((i = ''${#parents[@]} - 1; i >= 0; i--)); do
          addDir "''${parents[$i]}"
        done
        return 0
      }

      addBind() {
        local src dst key
        src="$1"
        dst="$2"
        key="bind $src -> $dst"

        if [ -n "''${JAIL_RO_BINDS_SEEN[$key]-}" ]; then
          if [ "''${JAIL_DEBUG_PATHS-}" = 1 ]; then
            echo "readonly-paths-from-var-resolved: skip queued bind $src -> $dst" >&2
          fi
          return 0
        fi

        if existingBwrapPathExists "$dst" || coveringBwrapPathExists "$dst"; then
          if [ "''${JAIL_DEBUG_PATHS-}" = 1 ]; then
            echo "readonly-paths-from-var-resolved: skip existing bind $src -> $dst" >&2
          fi
          return 0
        fi

        JAIL_RO_BINDS_SEEN[$key]=1
        addParentDirs "$dst"
        JAIL_QUEUED_BIND_SRCS[$dst]="$src"
        if [ "''${JAIL_DEBUG_PATHS-}" = 1 ]; then
          echo "readonly-paths-from-var-resolved: queue bind $src -> $dst" >&2
        fi
        return 0
      }

      flushQueuedMounts() {
        local path dst src
        local dir_index bind_index

        dir_index=0
        bind_index=0

        if [ "''${#JAIL_DIRS_SEEN[@]}" -gt 0 ]; then
          while IFS= read -r path; do
            [ -n "$path" ] || continue
            dir_index=$((dir_index + 1))
            if [ "''${JAIL_DEBUG_PATHS-}" = 1 ]; then
              echo "readonly-paths-from-var-resolved: flush dir[$dir_index] $path" >&2
            fi
            RUNTIME_ARGS+=(--dir "$path")
          done < <(printf '%s\n' "''${!JAIL_DIRS_SEEN[@]}" | LC_ALL=C sort)
        fi

        if [ "''${#JAIL_QUEUED_BIND_SRCS[@]}" -gt 0 ]; then
          while IFS= read -r dst; do
            [ -n "$dst" ] || continue
            src="''${JAIL_QUEUED_BIND_SRCS[$dst]}"
            bind_index=$((bind_index + 1))
            if [ "''${JAIL_DEBUG_PATHS-}" = 1 ]; then
              echo "readonly-paths-from-var-resolved: flush bind[$bind_index] $src -> $dst" >&2
            fi
            RUNTIME_ARGS+=(--ro-bind "$src" "$dst")
          done < <(printf '%s\n' "''${!JAIL_QUEUED_BIND_SRCS[@]}" | LC_ALL=C sort)
        fi

        return 0
      }

      addNixStoreRoot() {
        local path
        path="$1"

        if [[ "$path" == /nix/store/* ]]; then
          addBind /nix/store /nix/store
        fi
        return 0
      }

      resolvePath() {
        local path target
        local depth=0
        path="$1"

        while [ -L "$path" ]; do
          if (( depth >= 10 )); then
            echo "jail.nix: refusing to resolve more than 10 symlink levels for $1" >&2
            return 1
          fi

          target="$(readlink "$path")"
          if [[ "$target" = /* ]]; then
            path="$target"
          else
            path="$(realpath -m "$(dirname "$path")/$target")"
          fi

          depth=$((depth + 1))
        done

        realpath -e "$path"
      }

      bindResolvedPath() {
        local path resolved
        path="$1"

        if ! [ -e "$path" ]; then
          return 0
        fi

        resolved="$(resolvePath "$path")" || exit 1
        addBind "$path" "$path"
        if [ "$resolved" != "$path" ]; then
          addBind "$resolved" "$resolved"
          addNixStoreRoot "$resolved"
        fi
        return 0
      }

      bindResolvedTarget() {
        local path resolved
        path="$1"

        if ! [ -e "$path" ]; then
          return 0
        fi

        resolved="$(resolvePath "$path")" || exit 1
        if [ "$resolved" != "$path" ]; then
          addBind "$resolved" "$resolved"
          addNixStoreRoot "$resolved"
        fi
        return 0
      }

      rememberExistingBwrapPaths

      IFS=${lib.escapeShellArg separator} read -ra DIRS <<< "''${${var}-}"
      for DIR in "''${DIRS[@]}"; do
        if ! [ -e "$DIR" ]; then
          continue
        fi

        RESOLVED_DIR="$(resolvePath "$DIR")" || exit 1
        bindResolvedPath "$DIR"

        case "$DIR:$RESOLVED_DIR" in
          /nix/store/*|*:/nix/store/*|/usr:*|/usr/*|*:/usr|*:/usr/*|/bin:*|/sbin:*)
            continue
          ;;
        esac

        for ENTRY in "$DIR"/*; do
          [ -L "$ENTRY" ] || continue
          bindResolvedTarget "$ENTRY"
        done
      done

      flushQueuedMounts
    '');
}
