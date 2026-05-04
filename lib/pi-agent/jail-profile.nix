{ lib }:
{ jail, inventory, jailHome ? "/tmp/pi-home", hostHomeVar ? "PI_HOST_HOME" }:
with jail.combinators;
let
  forwardedEnv = inventory.normalizedProfile.jail.forwardedEnv;
  statePaths = inventory.normalizedProfile.jail.statePaths;
  shareNetwork = inventory.normalizedProfile.jail.shareNetwork;
  agentHome = "${jailHome}/.pi/agent";
  managedDirEntries = builtins.filter (entry: entry.kind == "dir") inventory.managedEntries;
  managedDirArgs = lib.concatMapStrings (entry: "      --dir ${agentHome}/${entry.targetRelativePath}\n") managedDirEntries;
  managedBindArgs = lib.concatMapStrings (
    entry:
    "      --ro-bind ${lib.escapeShellArg (toString entry.source)} ${lib.escapeShellArg "${agentHome}/${entry.targetRelativePath}"}\n"
  ) inventory.managedEntries;
  statePathIsFile = statePath: lib.any (suffix: lib.hasSuffix suffix statePath) [ ".json" ".jsonl" ];
  hostStatePath = relativePath: "\"$" + hostHomeVar + "/${relativePath}\"";
  stateScaffoldScript = lib.concatMapStrings (
    statePath:
    let
      target = hostStatePath statePath;
    in
    if statePathIsFile statePath then
      ''
        mkdir -p "$(dirname ${target})"
        if [ ! -e ${target} ]; then
          : > ${target}
        fi
      ''
    else
      ''
        mkdir -p ${target}
      ''
  ) statePaths;
  stateBindArgs = lib.concatMapStrings (
    statePath: "      --bind ${hostStatePath statePath} ${jailHome}/${statePath}\n"
  ) statePaths;
in
[
  (ro-bind-all-in-except "/" "/" [
    "tmp"
    "proc"
    "sys"
    "dev"
    "home"
  ])

  mount-cwd
  capture-host-home
  (safe-path-from-var-resolved "PATH" ":")
  (minimal-env jailHome forwardedEnv)
]
++ [
  (add-runtime ''
${stateScaffoldScript}  '')
]
++ [
  (add-runtime ''
    RUNTIME_ARGS+=(
      --dir ${agentHome}
      --dir ${agentHome}/extensions
      --dir ${agentHome}/skills
      --dir ${agentHome}/prompts
      --dir ${agentHome}/themes
${stateBindArgs}${managedDirArgs}${managedBindArgs}    )
  '')
]
++ lib.optionals shareNetwork [
  (share-ns "net")
]
