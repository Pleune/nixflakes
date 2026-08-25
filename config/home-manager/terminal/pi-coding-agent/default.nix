{
  lib,
  config,
  pkgs,
  ...
}:
with lib;
let
  cfg = config.nixflakes.programs.pi-coding-agent;

  piAgentLib = import ../../../../lib/pi-coding-agent {
    inherit lib;
  };

  profile = import ../../../pi-coding-agent/profile.nix {
    inherit pkgs;
  };

  #
  # Build the canonical inventory once.
  #
  # The complete inventory is passed through to the nixflakes implementation
  # so that resource installation and jail construction operate on exactly the
  # same normalized profile.
  #

  inventory = piAgentLib.inventoryFromProfile {
    inherit pkgs profile;
  };

  entries = inventory.managedEntries;

  #
  # Locate a final inventory entry by its Pi agent-relative target.
  #
  # inventoryFromProfile has already resolved collisions.
  #

  findEntry =
    targetRelativePath:
    lib.findFirst (
      entry:
      entry.targetRelativePath == targetRelativePath
    ) null entries;

  #
  # Convert well-known JSON resources from the portable profile into the
  # structured values expected by the upstream Home Manager module.
  #

  readJsonEntry =
    targetRelativePath:
    let
      entry = findEntry targetRelativePath;
    in
    if entry == null then
      { }
    else if entry.kind != "file" then
      throw ''
        pi-coding-agent: ${targetRelativePath} must be a file, but the profile
        produced a ${entry.kind} resource
      ''
    else
      builtins.fromJSON (
        builtins.readFile entry.source
      );

  #
  # Upstream accepts AGENTS.md as a path through its `context` option, so
  # preserve the store path rather than reading it back into a string.
  #

  contextEntry = findEntry "AGENTS.md";

  context =
    if contextEntry == null then
      ""
    else if contextEntry.kind != "file" then
      throw ''
        pi-coding-agent: AGENTS.md must be a file, but the profile produced a
        ${contextEntry.kind} resource
      ''
    else
      contextEntry.source;

in
{
  config = mkIf cfg.enable {
    #
    # Delegate standard Pi configuration to the real upstream Home Manager
    # module.
    #
    # package = null is intentional. Upstream owns the standard configuration
    # files, while nixflakes installs the jailed executable.
    #

    programs.pi-coding-agent = {
      enable = true;

      package = null;

      settings =
        mkDefault (
          readJsonEntry "settings.json"
        );

      keybindings =
        mkDefault (
          readJsonEntry "keybindings.json"
        );

      models =
        mkDefault (
          readJsonEntry "models.json"
        );

      context =
        mkDefault context;
    };

    #
    # Pass the complete inventory to the nixflakes implementation.
    #
    # The implementation creates a filtered view for Home Manager resource
    # links, but passes this original inventory to jailProfile so packaged
    # resource information is preserved.
    #

    nixflakes.programs.pi-coding-agent.inventory =
      mkDefault inventory;
  };
}