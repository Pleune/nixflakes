{ lib }:
let
  inherit (builtins)
    attrNames
    baseNameOf
    filter
    foldl'
    fromJSON
    hasAttr
    head
    length
    pathExists
    readDir
    readFile
    sort
    stringLength
    substring
    ;

  hasPrefix =
    prefix: value:
    let
      prefixLength = stringLength prefix;
      valueLength = stringLength value;
    in
    valueLength >= prefixLength && substring 0 prefixLength value == prefix;

  hasSuffix =
    suffix: value:
    let
      suffixLength = stringLength suffix;
      valueLength = stringLength value;
    in
    valueLength >= suffixLength && substring (valueLength - suffixLength) suffixLength value == suffix;

  removePrefix =
    prefix: value:
    if hasPrefix prefix value then
      substring (stringLength prefix) (stringLength value - stringLength prefix) value
    else
      value;

  isPattern =
    value:
    hasPrefix "!" value
    || hasPrefix "+" value
    || hasPrefix "-" value
    || builtins.match ".*[\\*\\?].*" value != null;

  isHidden = name: hasPrefix "." name;
  isSkillMarkdown = name: hasSuffix ".md" name && name != "README.md";
  isPromptMarkdown = name: hasSuffix ".md" name;
  isThemeJson = name: hasSuffix ".json" name;
  isExtensionFile =
    name:
    hasSuffix ".ts" name || hasSuffix ".js" name || hasSuffix ".mjs" name || hasSuffix ".cjs" name;

  readDirIfExists = path: if pathExists path then readDir path else { };
  readJsonIfExists = path: if pathExists path then fromJSON (readFile path) else { };

  topLevelEntries =
    dir: predicate:
    let
      entries = readDirIfExists dir;
    in
    sort builtins.lessThan (
      filter (
        name:
        let
          type = builtins.getAttr name entries;
        in
        !isHidden name && predicate name type
      ) (attrNames entries)
    );

  mkEntry = tier: kind: source: targetRelativePath: {
    inherit tier kind source;
    targetRelativePath = builtins.unsafeDiscardStringContext targetRelativePath;
  };

  collectRootEntries =
    tier: root:
    let
      skillDirNames = topLevelEntries (root + "/skills") (
        _name: type: type == "directory" || type == "symlink"
      );
      skillFileNames = topLevelEntries (root + "/skills") (
        name: type: type == "regular" && isSkillMarkdown name
      );
      extensionDirNames = topLevelEntries (root + "/extensions") (
        _name: type: type == "directory" || type == "symlink"
      );
      extensionFileNames = topLevelEntries (root + "/extensions") (
        name: type: type == "regular" && isExtensionFile name
      );
      promptNames = topLevelEntries (root + "/prompts") (
        name: type: (type == "regular" || type == "symlink") && isPromptMarkdown name
      );
      themeNames = topLevelEntries (root + "/themes") (
        name: type: (type == "regular" || type == "symlink") && isThemeJson name
      );
    in
    (lib.optionals (pathExists (root + "/AGENTS.md")) [
      (mkEntry tier "file" (root + "/AGENTS.md") "AGENTS.md")
    ])
    ++ (lib.optionals (pathExists (root + "/APPEND_SYSTEM.md")) [
      (mkEntry tier "file" (root + "/APPEND_SYSTEM.md") "APPEND_SYSTEM.md")
    ])
    ++ map (
      name: mkEntry tier "dir" (root + "/extensions/${name}") "extensions/${name}"
    ) extensionDirNames
    ++ map (
      name: mkEntry tier "file" (root + "/extensions/${name}") "extensions/${name}"
    ) extensionFileNames
    ++ map (name: mkEntry tier "dir" (root + "/skills/${name}") "skills/${name}") skillDirNames
    ++ map (name: mkEntry tier "file" (root + "/skills/${name}") "skills/${name}") skillFileNames
    ++ map (name: mkEntry tier "file" (root + "/prompts/${name}") "prompts/${name}") promptNames
    ++ map (name: mkEntry tier "file" (root + "/themes/${name}") "themes/${name}") themeNames;

    packageRootFor = pkg:
      let
        nodeModulesDir = pkg + "/lib/node_modules";
    
        packageNames = topLevelEntries nodeModulesDir (
          name: type:
          (type == "directory" || type == "symlink")
          && !(hasPrefix "@" name)
        );
    
        packageName = lib.getName pkg;
    
        exactPackageRoot =
          nodeModulesDir + "/${packageName}";
      in
      if pathExists exactPackageRoot then
        exactPackageRoot
      else if packageNames == [ ] then
        null
      else
        nodeModulesDir + "/${head packageNames}";

  manifestFor =
    packageRoot:
    let
      packageJson = readJsonIfExists (packageRoot + "/package.json");
    in
    if packageJson ? pi then packageJson.pi else { };

  sourceEntriesFor =
    manifest: key:
    if hasAttr key manifest then
      filter (entry: !(isPattern entry)) (builtins.getAttr key manifest)
    else
      [ ];

  resolvePackageEntry =
    packageRoot: entry:
    let
      cleanEntry = removePrefix "./" entry;
    in
    packageRoot + "/${cleanEntry}";

  collectSkillEntriesFromPath =
    tier: path:
    let
      entries = readDirIfExists path;
      names = sort builtins.lessThan (attrNames entries);
      filteredNames = filter (
        name:
        let
          type = builtins.getAttr name entries;
        in
        !isHidden name
        && (type == "directory" || type == "symlink" || (type == "regular" && isSkillMarkdown name))
      ) names;
      dirNames = filter (
        name:
        let
          type = builtins.getAttr name entries;
        in
        type == "directory" || type == "symlink"
      ) filteredNames;
      fileNames = filter (
        name:
        let
          type = builtins.getAttr name entries;
        in
        type == "regular" && isSkillMarkdown name
      ) filteredNames;
    in
    map (name: mkEntry tier "dir" (path + "/${name}") "skills/${name}") dirNames
    ++ map (name: mkEntry tier "file" (path + "/${name}") "skills/${name}") fileNames;

  collectPromptEntriesFromPath =
    tier: path:
    let
      entries = readDirIfExists path;
      names = sort builtins.lessThan (attrNames entries);
      fileNames = filter (
        name:
        let
          type = builtins.getAttr name entries;
        in
        !isHidden name && (type == "regular" || type == "symlink") && isPromptMarkdown name
      ) names;
    in
    map (name: mkEntry tier "file" (path + "/${name}") "prompts/${name}") fileNames;

  collectThemeEntriesFromPath =
    tier: path:
    let
      entries = readDirIfExists path;
      names = sort builtins.lessThan (attrNames entries);
      fileNames = filter (
        name:
        let
          type = builtins.getAttr name entries;
        in
        !isHidden name && (type == "regular" || type == "symlink") && isThemeJson name
      ) names;
    in
    map (name: mkEntry tier "file" (path + "/${name}") "themes/${name}") fileNames;

  collectPackageEntries =
    tier: pkgs: packages:
    builtins.concatMap (
      pkg:
      let
        packageRoot = packageRootFor pkg;
      in
      if packageRoot == null || !(pathExists (packageRoot + "/package.json")) then
        [ ]
      else
        let
          manifest = manifestFor packageRoot;
          packageDirName = baseNameOf packageRoot;
          skillRoots = map (entry: resolvePackageEntry packageRoot entry) (
            sourceEntriesFor manifest "skills"
          );
          promptRoots = map (entry: resolvePackageEntry packageRoot entry) (
            sourceEntriesFor manifest "prompts"
          );
          themeRoots = map (entry: resolvePackageEntry packageRoot entry) (
            sourceEntriesFor manifest "themes"
          );
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
              cleanPath = removePrefix "./" relativePath;
              basename = lib.last (lib.splitString "/" cleanPath);
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
            mkEntry tier "dir" projectedRoot "extensions/${targetName}";

          collectExtensionEntries = map projectExtensionPath extensionRoots;
        in
        collectExtensionEntries
        ++ builtins.concatMap (path: collectSkillEntriesFromPath tier path) (filter pathExists skillRoots)
        ++ builtins.concatMap (path: collectPromptEntriesFromPath tier path) (filter pathExists promptRoots)
        ++ builtins.concatMap (path: collectThemeEntriesFromPath tier path) (filter pathExists themeRoots)
    ) packages;

  reverseList = list: foldl' (acc: item: [ item ] ++ acc) [ ] list;

  keepLastByTarget =
    entries:
    let
      result =
        foldl'
          (
            acc: entry:
            if hasAttr entry.targetRelativePath acc.seen then
              acc
            else
              {
                seen = acc.seen // {
                  ${entry.targetRelativePath} = true;
                };
                kept = [ entry ] ++ acc.kept;
              }
          )
          {
            seen = { };
            kept = [ ];
          }
          (reverseList entries);
    in
    result.kept;
in
{
  pkgs ? null,
  profile,
}:
let
  normalizedProfile = {
    resources = {
      roots = lib.unique (profile.resources.roots or [ ]);
      packages = lib.unique (profile.resources.packages or [ ]);
    };
    jail = {
      forwardedEnv = lib.unique (profile.jail.forwardedEnv or [ ]);
      shareNetwork = profile.jail.shareNetwork or false;
      statePaths = lib.unique (profile.jail.statePaths or [ ]);
    };
  };

  packageEntries = collectPackageEntries "packages" pkgs normalizedProfile.resources.packages;
  rootEntries = builtins.concatMap (
    root: collectRootEntries "roots" root
  ) normalizedProfile.resources.roots;
  managedEntries = keepLastByTarget (packageEntries ++ rootEntries);
in
{
  inherit
    normalizedProfile
    packageEntries
    rootEntries
    managedEntries
    ;
}
