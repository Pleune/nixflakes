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
  isPattern =
    value:
    lib.hasPrefix "!" value
    || lib.hasPrefix "+" value
    || lib.hasPrefix "-" value
    || builtins.match ".*[\\*\\?].*" value != null;
  readDirIfExists = path: if builtins.pathExists path then builtins.readDir path else { };
  readJsonIfExists = path: if builtins.pathExists path then builtins.fromJSON (builtins.readFile path) else { };

  topLevelEntries = dir: predicate:
    let
      entries = readDirIfExists dir;
    in
    lib.sort builtins.lessThan (
      lib.filter (
        name:
        let
          type = builtins.getAttr name entries;
        in
        !isHidden name && predicate name type
      ) (builtins.attrNames entries)
    );

  packageRootFor = pkg:
    let
      nodeModulesDir = pkg + "/lib/node_modules";
      packageNames = topLevelEntries nodeModulesDir (
        name: type:
        (type == "directory" || type == "symlink")
        && !(lib.hasPrefix "@" name)
      );
      packageName = lib.getName pkg;
      exactPackageRoot = nodeModulesDir + "/${packageName}";
    in
    if builtins.pathExists exactPackageRoot then
      exactPackageRoot
    else if packageNames == [ ] then
      null
    else
      nodeModulesDir + "/${builtins.head packageNames}";

  manifestFor = packageRoot:
    let
      packageJson = readJsonIfExists (packageRoot + "/package.json");
    in
    if builtins.hasAttr "pi" packageJson then packageJson.pi else { };

  sourceEntriesFor = manifest: key:
    if builtins.hasAttr key manifest then
      lib.filter (entry: !isPattern entry) (builtins.getAttr key manifest)
    else
      [ ];

  resolvePackageEntry = packageRoot: entry: packageRoot + "/${lib.removePrefix "./" entry}";

  collectPackageResources = packages:
    builtins.foldl'
      (
        acc: pkg:
        let
          packageRoot = packageRootFor pkg;
        in
        if packageRoot == null || !(builtins.pathExists (packageRoot + "/package.json")) then
          acc
        else
          let
            manifest = manifestFor packageRoot;
            packageDirName = builtins.baseNameOf packageRoot;
            extensionRoots = sourceEntriesFor manifest "extensions";
            extensionCount = builtins.length extensionRoots;

            deriveExtensionFeatureId =
              cleanPath:
              let
                withoutIndex = lib.removeSuffix "/index.js" (lib.removeSuffix "/index.ts" cleanPath);
                withoutExtension = lib.removeSuffix ".js" (lib.removeSuffix ".ts" withoutIndex);
                strippedCommonPrefix = lib.removePrefix "src/extensions/" (
                  lib.removePrefix "extensions/" (
                    lib.removePrefix "src/" (lib.removePrefix "build/" (lib.removePrefix "dist/" withoutExtension))
                  )
                );
                preferredPath =
                  if
                    strippedCommonPrefix == ""
                    || builtins.elem strippedCommonPrefix [
                      "index"
                      "src"
                      "extension"
                      "pi-extension"
                    ]
                  then
                    withoutExtension
                  else
                    strippedCommonPrefix;
                normalizedPath = if preferredPath == "" then "index" else preferredPath;
              in
              builtins.replaceStrings [ "/" ] [ "-" ] normalizedPath;

            projectExtensionPath =
              relativePath:
              let
                cleanPath = lib.removePrefix "./" relativePath;
                basename = builtins.baseNameOf cleanPath;
                isFile = lib.hasInfix "." basename;
                featureId = deriveExtensionFeatureId cleanPath;
                targetName = if extensionCount == 1 then packageDirName else "${packageDirName}-${featureId}";
                wrapperFileName = if lib.hasSuffix ".js" cleanPath then "index.js" else "index.ts";
                needsWrapper = !(!isFile || cleanPath == "index.ts" || cleanPath == "index.js");
                projectedRoot =
                  if needsWrapper then
                    let
                      projection = pkgs.runCommand "pi-extension-${targetName}" { } ''
                        mkdir -p "$out/${targetName}"
                        cp -r ${packageRoot}/. "$out/${targetName}/"
                        chmod -R u+w "$out/${targetName}"
                        cat > "$out/${targetName}/${wrapperFileName}" <<'WRAPPER_EOF'
                        export { default } from "./${cleanPath}";
                        WRAPPER_EOF
                        cat > "$out/${targetName}/package.json" <<'MANIFEST_EOF'
                        ${builtins.toJSON (
                          readJsonIfExists (packageRoot + "/package.json")
                          // {
                            pi = manifest // {
                              extensions = [ "./${wrapperFileName}" ];
                            };
                          }
                        )}
                        MANIFEST_EOF
                      '';
                    in
                    projection + "/${targetName}"
                  else
                    packageRoot;
              in
              projectedRoot;
          in
          acc // {
            extensions = acc.extensions ++ map projectExtensionPath extensionRoots;
          }
      )
      {
        extensions = [ ];
      }
      packages;

  extensionPackages = [
    pkgs.pi-ask
    pkgs.pi-antigravity
    pkgs.pi-subagents
    pkgs.rpiv-btw
    pkgs.rpiv-todo
    pkgs.pi-token-burden
  ];

  packageResources = collectPackageResources extensionPackages;

in
{
  pi.coding-agent = {
    rules = rules;
    skills = [ (resourcesRoot + "/skills") ];
    promptTemplates = [ (resourcesRoot + "/prompts") ];
    themes = [ (resourcesRoot + "/themes") ];
    extensions = packageResources.extensions;

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
