{
  lib,
  config,
  pkgs,
  ...
}:
with lib;
{
  options.nixflakes.programs.keepassxc.enable = mkEnableOption "KeePassXC";

  config = mkIf config.nixflakes.programs.keepassxc.enable {
    programs.keepassxc = {
      enable = true;
      package = pkgs.keepass-unlocker.keepassxc;
      settings = {
        Browser = {
          Enabled = true;
          UpdateBinaryPath = false;
          ChromiumEnabled = true;
          FirefoxEnabled = true;
        };
        GUI = {
          AdvancedSettings = true;
          CompactMode = true;
        };
        SSHAgent.Enabled = true;
        Security.IconDownloadFallback = true;
      };
    };
  };
}
