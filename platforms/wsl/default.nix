{ username, hostName, NixOS-WSL, ... }:

{
  imports = [ NixOS-WSL.nixosModules.wsl ];
  wsl = {
    enable = true;
    defaultUser = "${username}";
    nativeSystemd = true;
  };

  time.timeZone = "America/Detroit";
  i18n.defaultLocale = "en_US.UTF-8";
}
