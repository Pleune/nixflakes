{ config, pkgs, username, ... }:

{
  imports =
    [
      ./hardware-configuration.nix
    ];

  time.timeZone = "America/Detroit";
  i18n.defaultLocale = "en_US.UTF-8";

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  networking.networkmanager.enable = true;

  environment.sessionVariables = { LIBVA_DRIVER_NAME = "iHD"; }; # Force intel-media-driver

  services.xserver = {
    enable = true;
    displayManager = {
      gdm = {
        enable = true;
        wayland = true;
      };
      setupCommands = ''
        if [ $XDG_SESSION_TYPE == "wayland" ]; then export QT_QPA_PLAYFORM="wayland"; fi
      '';
    };
    desktopManager.gnome.enable = true;

    xkb = {
      layout = "us";
      variant = "";
    };
  };
  environment.gnome.excludePackages = with pkgs; [ snapshot ];
  environment.systemPackages = with pkgs; [ gnome.cheese ];
  services.gnome = 
  {
    games.enable = true;
  };

  services.printing.enable = true;

  users.users.${username}.extraGroups = [ "networkmanager" "video" ];
}
