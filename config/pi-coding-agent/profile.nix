{ lib, pkgs }:
let
  resourcesRoot = ./resources;

  forwardedEnv = [
    "OPENAI_API_KEY"
    "ANTHROPIC_API_KEY"
    "GOOGLE_API_KEY"
    "MISTRAL_API_KEY"
    "DEEPSEEK_API_KEY"
    "XAI_API_KEY"
  ];

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
    pkgs.pi-ask
    pkgs.pi-antigravity
    pkgs.pi-subagents
    pkgs.rpiv-btw
    pkgs.rpiv-todo
    pkgs.pi-token-burden
  ];

  extensions = lib.concatMap extensionFor extensionPackages;
in
{
  pi.coding-agent = {
    rules = rules;
    skills = [ (resourcesRoot + "/skills") ];
    promptTemplates = [ (resourcesRoot + "/prompts") ];
    themes = [ (resourcesRoot + "/themes") ];
    inherit extensions;

    jail.enable = true;
    jail.permissions = combinators:
      let
        jailCombinators = import ../../lib/jail/combinators.nix {
          inherit combinators pkgs;
          lib = pkgs.lib;
        };

        statePaths = [
          ".pi/agent/auth.json"
          ".pi/agent/mcp-cache.json"
          ".pi/agent/memory"
          ".pi/agent/models.json"
          ".pi/agent/projects-memory"
          ".pi/agent/run-history.jsonl"
          ".pi/agent/sessions"
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
      [
        (jailCombinators.ro-bind-all-in-except "/" "/" [
          "tmp"
          "proc"
          "sys"
          "dev"
          "home"
        ])

        mount-cwd
        (jailCombinators.capture-host-home)
        (jailCombinators.safe-path-from-var-resolved "PATH" ":")
        (jailCombinators.minimal-env "/tmp/pi-home" forwardedEnv)
        (add-runtime ''
${statePathCommands}        '')
        (share-ns "net")
      ];
  };
}
