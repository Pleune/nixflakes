{
  pkgs,
  lib,
  userFullName,
  config,
  ...
}:
{
  options.nixflakes.gpg = lib.mkEnableOption "GPG intergrations";
  config = lib.mkIf config.nixflakes.gpg {
    programs.gpg = {
      enable = true;
    };
    services.gpg-agent = {
      enable = true;
      pinentryPackage = lib.mkDefault pkgs.pinentry-tty;
    };
    programs.git.signing = {
      signByDefault = true;
      key = "${userFullName}";
    };
  };
}
