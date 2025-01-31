{
  username,
  ...
}:
{
  nixpkgs.hostPlatform = {
    # gcc.arch = "x86-64-v3";
    # gcc.tune = "alderlake";
    system = "x86_64-linux";
  };

  isoImage.edition = "nixflakes";
  #boot.kernelParams = [ "copytoram" ];

  time.timeZone = "America/Detroit";
  i18n.defaultLocale = "en_US.UTF-8";

  # use network manager over wpa_supplicant
  networking.wireless.enable = false;
  networking.networkmanager.enable = true;

  services = {
    displayManager.autoLogin = {
      enable = true;
      user = username;
    };
    xserver = {
      enable = true;
      displayManager = {
        gdm = {
          enable = true;
          autoSuspend = false;
          wayland = true;
        };
      };

      desktopManager.gnome.enable = true;

      xkb = {
        layout = "us";
        variant = "";
      };
    };
  };

  zramSwap.enable = true;

  users.users.${username}.extraGroups = [
    "networkmanager"
    "video"
  ];

  home-manager.users.${username} = {
    nixflakes = {
      theme = "gnome";
      gui = true;
      daily = false;
    };
  };
}
