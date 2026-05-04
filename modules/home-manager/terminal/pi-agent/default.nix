{
  lib,
  config,
  pkgs,
  jail-nix,
  ...
}:
with lib;
let
  cfg = config.nixflakes.programs.pi-agent;
  jailLib = import ../../../../lib/jail {
    inherit jail-nix pkgs;
  };
  piAgentLib = import ../../../../lib/pi-agent { inherit lib; };
  inventory = piAgentLib.inventoryFromProfile {
    inherit pkgs;
    profile = cfg.profile;
  };
  linkSpecs = piAgentLib.homeLinkSpecs { inherit inventory; };
  agentHomeRelative = ".pi/agent";
  homeDirLinkCommands = concatMapStringsSep "\n" (
    link:
    let
      target = "${config.home.homeDirectory}/${agentHomeRelative}/${link.targetRelativePath}";
      source = toString link.source;
    in
    ''
      mkdir -p ${escapeShellArg (dirOf target)}
      rm -rf ${escapeShellArg target}
      ln -s ${escapeShellArg source} ${escapeShellArg target}
    ''
  ) linkSpecs.dirEntries;
  homeFiles = builtins.listToAttrs (map (
    link: {
      name = "${agentHomeRelative}/${link.targetRelativePath}";
      value = {
        source = link.source;
        force = true;
        recursive = false;
      };
    }
  ) linkSpecs.fileEntries);

  jail = jailLib.extend;
  wrappedPackage = jail "pi" pkgs.pi-agent (
    piAgentLib.jailProfile {
      inherit jail inventory;
    }
  );
in
{
  options.nixflakes.programs.pi-agent = {
    enable = mkEnableOption "pi-agent with Home Manager-managed resources and sandboxing";

    profile = mkOption {
      description = "Canonical pi-agent profile data consumed by the Home Manager module and flake-level mitchpi package.";
      default = { };
      type = types.submodule {
        options = {
          resources = mkOption {
            default = { };
            type = types.submodule {
              options = {
                roots = mkOption {
                  type = types.listOf types.path;
                  default = [ ];
                };
                packages = mkOption {
                  type = types.listOf types.package;
                  default = [ ];
                };
              };
            };
          };

          jail = mkOption {
            default = { };
            type = types.submodule {
              options = {
                forwardedEnv = mkOption {
                  type = types.listOf types.str;
                  default = [ ];
                };
                shareNetwork = mkOption {
                  type = types.bool;
                  default = false;
                };
                statePaths = mkOption {
                  type = types.listOf types.str;
                  default = [ ];
                };
              };
            };
          };
        };
      };
    };
  };

  config = mkIf cfg.enable {
    home.packages = [
      wrappedPackage
      pkgs.ripgrep
    ];

    home.file = homeFiles;

    home.activation.piAgentResourceDirLinks = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      ${homeDirLinkCommands}
    '';
  };
}
