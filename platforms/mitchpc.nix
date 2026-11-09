{
  username,
  config,
  lib,
  pkgs,
  modulesPath,
  ...
}:

{
  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
  ];

  boot.initrd.availableKernelModules = [
    "vmd"
    "xhci_pci"
    "ahci"
    "nvme"
    "usbhid"
    "usb_storage"
    "sd_mod"
  ];
  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [ "kvm-intel" ];
  boot.extraModulePackages = [ ];

  fileSystems."/" = {
    device = "/dev/disk/by-uuid/9ee2c9d3-a13b-4f72-912d-3d6decdc33c8";
    fsType = "ext4";
  };

  fileSystems."/boot" = {
    device = "/dev/disk/by-uuid/A232-1774";
    fsType = "vfat";
    options = [
      "fmask=0077"
      "dmask=0077"
    ];
  };

  swapDevices = [ ];

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
  hardware.cpu.intel.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;

  # Use the systemd-boot EFI boot loader.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # Use latest kernel.
  boot.kernelPackages = pkgs.linuxPackages_latest;

  # Intel Arc A770 GPU
  hardware.graphics = {
    enable = true;
    enable32Bit = true;

    extraPackages = with pkgs; [
      intel-media-driver
      vpl-gpu-rt
      intel-compute-runtime
      level-zero
    ];
  };

  # Intel video acceleration
  environment.sessionVariables = {
    LIBVA_DRIVER_NAME = "iHD";
  };

  # Intel GPU firmware
  hardware.enableRedistributableFirmware = true;

  networking.hostName = "mitchpc";
  networking.networkmanager.enable = true;
  networking.wireless.enable = true;

  users.users.${username}.extraGroups = [
    "networkmanager"
    "wheel"
    "video"
    "render"
  ];

  # Set your time zone.
  time.timeZone = "America/Detroit";

  # Select internationalisation properties.
  i18n.defaultLocale = "en_US.UTF-8";

  i18n.extraLocaleSettings = {
    LC_ADDRESS = "en_US.UTF-8";
    LC_IDENTIFICATION = "en_US.UTF-8";
    LC_MEASUREMENT = "en_US.UTF-8";
    LC_MONETARY = "en_US.UTF-8";
    LC_NAME = "en_US.UTF-8";
    LC_NUMERIC = "en_US.UTF-8";
    LC_PAPER = "en_US.UTF-8";
    LC_TELEPHONE = "en_US.UTF-8";
    LC_TIME = "en_US.UTF-8";
  };

  # Enable the GNOME Desktop Environment.
  services.displayManager.gdm.enable = true;
  services.desktopManager.gnome.enable = true;

  # Configure keymap in X11
  services.xserver.xkb = {
    layout = "us";
    variant = "";
  };

  # Enable CUPS to print documents.
  services.printing.enable = true;

  services.gnome = {
    gnome-online-accounts.enable = true;
    gnome-browser-connector.enable = true;
    games.enable = true;
  };

  # Enable sound with pipewire.
  services.pulseaudio.enable = false;
  security.rtkit.enable = true;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
    # If you want to use JACK applications, uncomment this
    # jack.enable = true;
  };

  # Steam
  programs.steam = {
    enable = true;

    # Steam Remote Play
    remotePlay.openFirewall = true;

    # Steam LAN game transfers
    localNetworkGameTransfers.openFirewall = true;

    # Dedicated server hosting
    dedicatedServer.openFirewall = true;

    # Steam Deck-like Gaming Mode session
    gamescopeSession.enable = true;

    # Additional Steam compatibility tools
    extraCompatPackages = with pkgs; [
      proton-ge-bin
    ];

    # Extra Steam runtime dependencies
    extraPackages = with pkgs; [
      gamemode
      mangohud
      gamescope
      protontricks
    ];

    # Enable Protontricks integration
    protontricks.enable = true;

    # Wayland Steam Input compatibility
    extest.enable = true;
  };

  # Gaming performance
  programs.gamemode.enable = true;

  # Gamescope compositor
  programs.gamescope = {
    enable = true;
    capSysNice = true;
    enableWsi = true;
  };

      # Gaming utilities
    environment.systemPackages = with pkgs; [
      mangohud
      protonup-qt
      protontricks
      gamescope
      gamemode
      vulkan-tools
      vulkan-loader
      vulkan-validation-layers
      steam-run
      winetricks
    ];


  home-manager.users.${username} = {
    home.packages = with pkgs; [
      libreoffice
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
        mitchvim.enable = true;
      };
    };
  };

  system.stateVersion = "26.05"; # Did you read the comment?
}
