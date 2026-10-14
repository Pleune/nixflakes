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

  nixpkgs.hostPlatform = {
    # gcc.arch = "skylake";
    # gcc.tune = "skylake";
    system = "x86_64-linux";
  };

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

  hardware = {
    enableAllFirmware = true;
    graphics = {
      enable = true;
      extraPackages = with pkgs; [
        mesa
        libvdpau-va-gl
      ];
    };
    cpu.intel.updateMicrocode = true;
    enableRedistributableFirmware = true;
    microsoft-surface.kernelVersion = "stable";
  };

  environment.sessionVariables = {
    LIBVA_DRIVER_NAME = "iHD";
  }; # Force intel-media-driver

  services = {
    logind.settings.Login.HandleLidSwitch = "hibernate";
    pulseaudio.enable = false;

    pipewire = {
      enable = true;
      alsa.enable = true;
      alsa.support32Bit = true;
      pulse.enable = true;
      jack.enable = true;
    };
  };

  security.rtkit.enable = true;

  time.timeZone = "America/Detroit";
  i18n.defaultLocale = "en_US.UTF-8";

  networking.networkmanager.enable = true;

  services = {
    displayManager = {
      gdm = {
        enable = true;
      };
    };
    desktopManager.gnome.enable = true;
    xserver = {
      enable = true;
      displayManager = {
        setupCommands = ''
          if [ $XDG_SESSION_TYPE == "wayland" ]; then export QT_QPA_PLAYFORM="wayland"; fi
        '';
      };

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
    systemPackages = with pkgs; [
      cheese
      pavucontrol # PulseAudio Volume Control
      pamixer # Command-line mixer for PulseAudio
    ];
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

    # TODO: build hang https://github.com/NixOS/nixpkgs/issues/431528#issuecomment-3175651671
    #printing.enable = true;
  };
  home-manager.users.${username} = {
    home.packages = with pkgs; [
      parsec-bin
      moonlight-qt
      discord
      prismlauncher
      spotify
      trilium-desktop
      xournalpp
      signal-desktop
      krita
      libreoffice
      vscode
    ];

    programs.thunderbird = {
      enable = true;
      profiles.default = {
        isDefault = true;
        withExternalGnupg = true;
      };
    };

    programs.awscli.enable = true;

    nixflakes = {
      theme.name = "gnome";
      programs = {
        firefox.enable = true;
        keepassxc.enable = true;
      };
    };
  };

  programs.steam.enable = true;

  system.stateVersion = "23.11";
}
