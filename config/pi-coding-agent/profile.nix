{
  lib,
  pkgs,
  persistCavemanConfig ? false,
}:
let
  resourcesRoot = ./resources;

  sandboxPermissions = import ../agent-sandbox/permissions.nix { inherit pkgs; };

  antigravityAcp = pkgs.writeShellScript "pi-antigravity-acp" ''
    # Keep the jail's calling identity; Google's default group lookup expects
    # a nobody group, which is not present in every sandbox's group database.
    exec ${lib.getExe pkgs.antigravity-acp} --uid= --gid= "$@"
  '';

  rules =
    builtins.readFile (resourcesRoot + "/AGENTS.md")
    + "\n\n"
    + builtins.readFile (resourcesRoot + "/APPEND_SYSTEM.md");

  isHidden = name: lib.hasPrefix "." name;
  extensionFor =
    pkg:
    pkg.passthru.extensions or [
      (
        let
          pname = pkg.pname or (lib.getName pkg);
          packageRoot = "${pkg}/lib/node_modules/${pname}";
          entry = pkg.passthru.entry or "index.ts";
        in
        "${packageRoot}/${entry}"
      )
    ];

  extensionPackages = [
    pkgs.billion-context
    pkgs.pi-ask
    pkgs.pi-antigravity-bridge
    pkgs.pi-subagents
    pkgs.rpiv-btw
    pkgs.rpiv-todo
    pkgs.pi-token-burden
    pkgs.pi-tps
    pkgs.pi-rtk-optimizer
    pkgs.pi-web-search
    pkgs.pi-caveman
    pkgs.pi-pretty
  ];

  extensions = lib.concatMap extensionFor extensionPackages;
in
{
  pi.coding-agent = {
    settings.defaultTools = [ "+codemode" ];
    rules = rules;
    skills = [ (resourcesRoot + "/skills") ];
    promptTemplates = [ (resourcesRoot + "/prompts") ];
    themes = [ (resourcesRoot + "/themes") ];
    inherit extensions;

    jail.enable = true;
    jail.permissions =
      combinators:
      let
        statePaths = [
          ".gemini/antigravity-acp"
          ".gemini/config"
          ".pi/agent/antigravity-bridge"
          ".pi/agent/auth.json"
          ".pi/agent/mcp-cache.json"
          ".pi/agent/memory"
          ".pi/agent/models.json"
          ".pi/agent/pi-pretty"
          ".pi/agent/projects-memory"
          ".pi/agent/run-history.jsonl"
          ".pi/agent/sessions"
        ]
        ++ lib.optionals persistCavemanConfig [
          ".config/pi/agent/caveman.json"
        ];

        statePathCommands = lib.concatMapStrings (
          statePath:
          let
            hostPath = "\"\${PI_HOST_HOME:-\$HOME}/${statePath}\"";
            targetPath = "\"\$PI_JAIL_HOME/${statePath}\"";
          in
          if lib.hasSuffix ".json" statePath || lib.hasSuffix ".jsonl" statePath then
            ''
              mkdir -p "$(dirname ${hostPath})" "$(dirname ${targetPath})"
              if [ ! -e ${hostPath} ]; then
                : > ${hostPath}
              fi
              RUNTIME_ARGS+=(--bind ${hostPath} ${targetPath})
            ''
          else
            ''
              mkdir -p ${hostPath} ${targetPath}
              RUNTIME_ARGS+=(--bind ${hostPath} ${targetPath})
            ''
        ) statePaths;
      in
      with combinators;
      sandboxPermissions combinators
      ++ [
        (add-runtime ''
          ${statePathCommands}

          # pi-pretty reads an optional pi-pretty.json; bind it only when the
          # host file exists so the jail never sees an empty config file.
          piPrettyConfig="''${PI_HOST_HOME:-$HOME}/.pi/agent/pi-pretty.json"
          if [ -f "$piPrettyConfig" ]; then
            mkdir -p "$PI_JAIL_HOME/.pi/agent"
            RUNTIME_ARGS+=(--ro-bind "$piPrettyConfig" "$PI_JAIL_HOME/.pi/agent/pi-pretty.json")
          fi
          RUNTIME_ARGS+=(--setenv PATH "$PATH:${pkgs.rtk}/bin:${pkgs.xdg-utils}/bin")

          # Pi-only desktop access for browser/OAuth opening. Keep isolated
          # HOME/XDG config; do not broaden the generic agent-sandbox policy.
          for piBrowserEnv in BROWSER DISPLAY WAYLAND_DISPLAY XDG_RUNTIME_DIR \
            DBUS_SESSION_BUS_ADDRESS XDG_CURRENT_DESKTOP XDG_SESSION_DESKTOP \
            DESKTOP_SESSION XDG_SESSION_TYPE XDG_DATA_DIRS \
            KDE_SESSION_VERSION KDE_FULL_SESSION; do
            if [ -n "''${!piBrowserEnv+x}" ]; then
              RUNTIME_ARGS+=(--setenv "$piBrowserEnv" "''${!piBrowserEnv}")
            fi
          done

          # /run (including normal Wayland/DBus sockets) is already visible.
          # Only project a Wayland socket separately when HOME or /tmp hides it.
          piWaylandSocket="''${WAYLAND_DISPLAY:-}"
          if [[ "$piWaylandSocket" != /* ]]; then
            piWaylandSocket="''${XDG_RUNTIME_DIR:-}/$piWaylandSocket"
          fi
          case "$piWaylandSocket" in
            /tmp/*|/home/*)
              if [ -n "''${WAYLAND_DISPLAY:-}" ] && [ -S "$piWaylandSocket" ]; then
                RUNTIME_ARGS+=(--ro-bind "$piWaylandSocket" "$piWaylandSocket")
              fi
              ;;
          esac

          if [[ "''${DISPLAY:-}" =~ ^(:|unix:)([0-9]+)(\.[0-9]+)?$ ]]; then
            piX11Socket="/tmp/.X11-unix/X''${BASH_REMATCH[2]}"
            if [ -S "$piX11Socket" ]; then
              RUNTIME_ARGS+=(--ro-bind "$piX11Socket" "$piX11Socket")
            fi
          fi
          piXAuthority="''${XAUTHORITY:-''${PI_HOST_HOME:-$HOME}/.Xauthority}"
          if [ -n "''${DISPLAY:-}" ] && [[ "$piXAuthority" = /* ]] && [ -f "$piXAuthority" ]; then
            RUNTIME_ARGS+=(--ro-bind "$piXAuthority" "$piXAuthority")
            RUNTIME_ARGS+=(--setenv XAUTHORITY "$piXAuthority")
          fi

          # Expose browser associations, not the entire host config directory.
          piBrowserConfig="''${XDG_CONFIG_HOME:-''${PI_HOST_HOME:-$HOME}/.config}"
          if [ -f "$piBrowserConfig/mimeapps.list" ]; then
            RUNTIME_ARGS+=(--ro-bind "$piBrowserConfig/mimeapps.list" "$PI_JAIL_XDG_CONFIG_HOME/mimeapps.list")
          fi

          # Google's allocator requires the kernel's possible CPU list.
          RUNTIME_ARGS+=(--ro-bind /sys/devices/system/cpu/possible /sys/devices/system/cpu/possible)
          RUNTIME_ARGS+=(--setenv AGY_ACP_BIN "${antigravityAcp}")
        '')
      ];
  };
}
