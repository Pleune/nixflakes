{
  lib,
  config,
  pkgs,
  ...
}:
with lib;
{
  options.nixflakes.programs.firefox.enable = mkEnableOption "Firefox";

  config = mkIf config.nixflakes.programs.firefox.enable {
    programs.firefox = {
      enable = true;
      package = pkgs.firefox;
      configPath = ".mozilla/firefox";
      nativeMessagingHosts = [ pkgs.gnome-browser-connector ];
      policies = {
        ExtensionSettings =
          let
            latestExtensionSourceURL =
              extensionId: "https://addons.mozilla.org/firefox/downloads/latest/${extensionId}/latest.xpi";
            extension = extensionId: {
              default_area = "menupanel";
              install_url = latestExtensionSourceURL extensionId;
              installation_mode = "normal_installed";
              private_browsing = true;
            };
            extensionIds = [
              "uBlock0@raymondhill.net"
              "keepassxc-browser@keepassxc.org"
              "gdpr@cavi.au.dk"
              "{74145f27-f039-47ce-a470-a662b129930a}"
            ];
          in
          lib.genAttrs extensionIds extension;
      };
      profiles.default = {
        settings = {
          "browser.startup.homepage" = "https://oskgovus.sharepoint.us/sites/prattmiller";
          "network.negotiate-auth.trusted-uris" = ".oshkoshglobal.com";
          "network.negotiate-auth.delegation-uris" = ".oshkoshglobal.com";
          "browser.download.always_ask_before_handling_new_types" = true;
          "signon.rememberSignons" = false;
          "signon.generation.enabled" = false;
          "signon.autofillForms" = false;
          "signon.showAutoCompleteFooter" = false;
        };
      };
    };
  };
}
