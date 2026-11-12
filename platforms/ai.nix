{
  username,
  config,
  lib,
  pkgs,
  modulesPath,
  ...
}:

{
  boot.initrd.availableKernelModules = [
    "nvme"
    "ahci"
    "xhci_pci"
    "usbhid"
    "usb_storage"
    "sd_mod"
  ];
  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [ "kvm-amd" ];
  boot.extraModulePackages = [ ];

  fileSystems."/" = {
    device = "/dev/disk/by-uuid/0ac80936-993e-4ab4-ac9f-c36b5684e63a";
    fsType = "ext4";
  };

  fileSystems."/boot" = {
    device = "/dev/disk/by-uuid/7775-3329";
    fsType = "vfat";
    options = [
      "fmask=0077"
      "dmask=0077"
    ];
  };

  swapDevices = [
    { device = "/dev/disk/by-uuid/0dd11fcf-bf0d-414c-9749-a326503086fb"; }
  ];

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
  hardware.cpu.amd.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;

  # Use the systemd-boot EFI boot loader.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  networking.networkmanager.enable = true;
  time.timeZone = "America/Detroit";
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

  # Configure keymap in X11
  services.xserver.xkb = {
    layout = "us";
    variant = "";
  };

  nixpkgs.config.allowUnfree = true;

  # Enable graphics
  hardware.graphics = {
    enable = true;
    enable32Bit = true;
  };

  # NVIDIA driver
  services.xserver.videoDrivers = [
    "nvidia"
    "amdgpu"
  ];

  hardware.nvidia = {
    open = false;
    package = config.boot.kernelPackages.nvidiaPackages.stable;

    # no desktop stuff
    modesetting.enable = false;
    nvidiaSettings = false;

    # prime = {
    #   offload = {
    #     enable = true;
    #     enableOffloadCmd = true;
    #   };
    #
    #   nvidiaBusId = "PCI:1:0:0";
    #   amdgpuBusId = "PCI:5:0:0";
    # };
  };

  environment.systemPackages = with pkgs; [
    cudaPackages.cudatoolkit
    # (lib.getBin config.hardware.nvidia.package)
    pciutils
    nvtopPackages.full
  ];

  services.openssh.enable = true;

  # The firewall is set once, below next to the Strata service that opens 8080 through
  # `openFirewall`; a second `networking.firewall` assignment here would be an eval error.

  # Copy the NixOS configuration file and link it from the resulting system
  # (/run/current-system/configuration.nix). This is useful in case you
  # accidentally delete configuration.nix.
  # system.copySystemConfiguration = true;

  # Strata: the local OpenAI/Anthropic-compatible inference server for Qwen3.8-Flash-Next.
  # This is the box the GPU lives in, so this is where the engine runs and where the llm
  # platform's hermes hooks point.
  #
  # Gyro-M (agentionai's Hadamard-folded Qwen3.8-Flash-Next, TQ2_0) is served on 131072 tokens
  # with int8 KV, matching the config used by hand before this service existed.  The quant is one
  # ~86 GB file: the first start downloads it and builds the pack (`iq_pack.py --compat-bf16`), so
  # the unit has no start timeout and the first converge after a deploy is slow.  Everything else
  # (expert cache, prefill, MTP draft layer, kv-resident) is derived by strata-prefetch and written
  # to /var/lib/strata/config.json, the same as Strata's own setup.sh does.
  #
  # Vision stays on the CPU: the GPU image encoder would keep ~1.4 GB of VRAM off the expert arena.
  nixflakes.services.strata = {
    enable = true;
    cudaArch = "86";
    family = "gyro";
    model = "Gyro-M";
    context = 131072;
    kv = "int8";
    port = 8080;
    vision = "cpu";
    gpus = [ "0" ];

    # Served to the LAN without an API key, so it is reachable by the llm host (and anything else
    # on PleuneNET).  `openFirewall` adds 8080 to the firewall, which is on for this host now.
    host = "0.0.0.0";
    allowUnauthenticated = true;
    openFirewall = true;

    # The server only answers to host names it knows; the domain the llm host (and Hermes) will
    # call has to be named here or the request comes back 403.
    allowedHosts = [ "ai.home.pleunetowne.com" ];

    # First start of the unit downloads about 92 GB into /var/lib/strata and builds the pack, which
    # takes a while (TimeoutStartSec is 0 so systemd does not kill it).  The old copy under
    # ~/Strata-data belongs to the installer-run server and is not read by the unit.
  };

  # Firewall on, for the sake of the model endpoint above.  openssh opens 22 itself, and Strata
  # opens 8080 through openFirewall; mDNS stays reachable because nixflakes.network.mdns is
  # enabled on every host and avahi answers on UDP 5353.
  networking.firewall = {
    enable = true;
    allowedUDPPorts = [ 5353 ];
  };

  users.users.${username}.extraGroups = [
    "video"
    "render"
  ];

  system.stateVersion = "26.05"; # Did you read the comment?
}
