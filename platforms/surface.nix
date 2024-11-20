{
  lib,
  pkgs,
  username,
  nixos-hardware,
  ...
}:

{
  imports = [
    nixos-hardware.nixosModules.microsoft-surface-pro-intel
  ];

  boot = {
    initrd = {
      availableKernelModules = [
        "xhci_pci"
        "nvme"
        "uas"
        "sd_mod"
      ];
      kernelModules = [ ];
    };
    loader = {
      systemd-boot.enable = true;
      efi.canTouchEfiVariables = true;
    };
    kernelModules = [ "kvm-intel" ];
    extraModulePackages = [ ];
  };

  zramSwap.enable = lib.mkDefault true;

  fileSystems."/" = {
    device = "/dev/disk/by-uuid/b3d0d09c-de9f-4b2c-97e6-5c9e2ee881b3";
    fsType = "ext4";
  };

  fileSystems."/boot" = {
    device = "/dev/disk/by-uuid/E09D-3563";
    fsType = "vfat";
  };

  swapDevices = [ { device = "/dev/disk/by-uuid/9538ea6d-604e-47fe-918b-f903dab4e79d"; } ];

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";

  hardware = {
    enableAllFirmware = true;
    graphics = {
      enable = true;
      extraPackages = with pkgs; [
        mesa.drivers
        libvdpau-va-gl
      ];
    };
    cpu.intel.updateMicrocode = true;
    enableRedistributableFirmware = true;
    pulseaudio.enable = false;
  };

  environment.sessionVariables = {
    LIBVA_DRIVER_NAME = "iHD";
  }; # Force intel-media-driver

  services = {
    logind.lidSwitch = "hibernate";

    pipewire = {
      enable = true;
      alsa.enable = true;
      alsa.support32Bit = true;
      pulse.enable = true;
    };
  };

  security.rtkit.enable = true;

  time.timeZone = "America/Detroit";
  i18n.defaultLocale = "en_US.UTF-8";

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
    systemPackages = with pkgs; [ cheese ];
    gnome.excludePackages = with pkgs; [ snapshot ];
  };
  users.users.${username}.extraGroups = [
    "networkmanager"
    "video"
    "surface-control"
  ];

  # My options
  nixflakes = {
    secureboot.enable = true;
    pleunenet.enable = true;
    printing.enable = true;
  };
  home-manager.users.${username}.nixflakes = {
    theme = "gnome";
  };

  system.stateVersion = "23.11";
}
