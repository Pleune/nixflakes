{ pkgs, username, NixOS-WSL, home-manager, ... }:
{
  imports = [ NixOS-WSL.nixosModules.wsl ];
  wsl = {
    enable = true;
    defaultUser = "${username}";
    nativeSystemd = true;
  };

  time.timeZone = "America/Detroit";
  i18n.defaultLocale = "en_US.UTF-8";

  hardware.opengl = {
    enable = true;

    extraPackages = with pkgs; [
      intel-media-driver # LIBVA_DRIVER_NAME=iHD
      intel-vaapi-driver # LIBVA_DRIVER_NAME=i965 (older but works better for Firefox/Chromium)
      libvdpau-va-gl
    ];
  };

  # just make vscode with the WSL remote extension work
  home-manager.users.${username}.home.file.".vscode-server/server-env-setup".text = "PATH=$PATH:/run/current-system/sw/bin/";
}
