{
  lib,
  pkgs,
  username,
  ...
}:

{
  imports = [
    ./hardware-configuration.nix
    ../../modules/system/printing
  ];

  time.timeZone = "America/Detroit";
  i18n.defaultLocale = "en_US.UTF-8";

  # Enables DHCP on each ethernet and wireless interface. In case of scripted networking
  # (the default) this is the recommended approach. When using systemd-networkd it's
  # still possible to use this option, but it's recommended to use it in conjunction
  # with explicit per-interface declarations with `networking.interfaces.<interface>.useDHCP`.
  networking.useDHCP = lib.mkDefault true;
  networking.wireguard.enable = lib.mkDefault true;
  networking.networkmanager.enable = true;

  services = {
    xserver = {
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

    gnome = {
      gnome-online-accounts.enable = true;
      gnome-browser-connector.enable = true;
      games.enable = true;
    };
  };

  environment = {
    systemPackages = with pkgs; [ gnome.cheese ];
    gnome.excludePackages = with pkgs; [ snapshot ];
  };
  users.users.${username}.extraGroups = [
    "networkmanager"
    "video"
  ];
}
