{
  lib,
  config,
  pkgs,
  ...
}:
with lib;
let
  keepassxcPackage =
    if config.programs.keepassxc.enable then config.programs.keepassxc.package else pkgs.keepassxc;
in
{
  options.nixflakes.programs.chromium.enable = mkEnableOption "Chromium";

  config = mkIf config.nixflakes.programs.chromium.enable {
    programs.chromium = {
      enable = true;
      package = pkgs.chromium;
      extensions = [
        { id = "oboonakemofpalcgghocfoadofidjkkk"; }
        { id = "cjpalhdlnbpafiamejdnhcphjbkeiagm"; }
        { id = "fnaicdffflnofjppbagibeoednhnbjhg"; }
      ];
      nativeMessagingHosts = [
        (pkgs.writeTextFile {
          name = "keepassxc-chromium-native-host";
          destination = "/etc/chromium/native-messaging-hosts/org.keepassxc.keepassxc_browser.json";
          text = builtins.toJSON {
            name = "org.keepassxc.keepassxc_browser";
            description = "KeePassXC integration with native messaging support";
            path = "${keepassxcPackage}/bin/keepassxc-proxy";
            type = "stdio";
            allowed_origins = [
              "chrome-extension://oboonakemofpalcgghocfoadofidjkkk/"
            ];
          };
        })
      ];
    };
  };
}
