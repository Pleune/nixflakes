{ pkgs, username, NixOS-WSL, home-manager, ... }:
{
  imports = [ NixOS-WSL.nixosModules.wsl ];
  wsl = {
    enable = true;
    defaultUser = "${username}";
    nativeSystemd = true;
    useWindowsDriver = true;
    startMenuLaunchers = true;
  };

  services.udev.enable = true;

  time.timeZone = "America/Detroit";
  i18n.defaultLocale = "en_US.UTF-8";

  hardware.opengl = {
    enable = true;
    driSupport = true;
    #driSupport32Bit = true;

    extraPackages = with pkgs; [
      mesa.drivers
      libvdpau-va-gl
      #intel-vaapi-driver
      #intel-media-driver
      vaapiVdpau
    ];
  };

  systemd.services."user-runtime-dir@" = {
    overrideStrategy = "asDropin";
    unitConfig.ConditionPathExists = "!/run/user/%i";
  };

  #environment.sessionVariables.LIBVA_DRIVER_NAME = "d3d12";
  environment.systemPackages = [ pkgs.glxinfo pkgs.libva-utils ];
  users.users.${username}.extraGroups = [ "video" ];
  # just make vscode with the WSL remote extension work
  #home-manager.users.${username}.home.file.".vscode-server/server-env-setup".text = "PATH=$PATH:/run/current-system/sw/bin/";
}
