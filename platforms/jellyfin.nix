{
  modulesPath,
  pkgs,
  config,
  private,
  ...
}:

{
  imports = [
    "${modulesPath}/virtualisation/lxc-container.nix"
  ];

  nixpkgs.hostPlatform = {
    # gcc.arch = "alderlake";
    # gcc.tune = "alderlake";
    system = "x86_64-linux";
  };

  networking = {
    dhcpcd.enable = false;
    useDHCP = false;
    useHostResolvConf = false;
  };

  systemd.network = {
    enable = true;
    networks."50-eth0" = {
      matchConfig.Name = "eth0";
      networkConfig = {
        DHCP = "ipv4";
        IPv6AcceptRA = true;
        MulticastDNS = true;
      };
      linkConfig.RequiredForOnline = "routable";
    };
  };

  # needed for resolving hdhomerun.local
  services.avahi.enable = true;

  nixpkgs.config.packageOverrides = pkgs: {
    intel-vaapi-driver = pkgs.intel-vaapi-driver.override { enableHybridCodec = true; };
  };
  hardware.graphics = {
    enable = true;
    extraPackages = with pkgs; [
      intel-media-driver
      intel-compute-runtime
      libvdpau-va-gl # VAAPI
      vpl-gpu-rt # QSV
      # intel-media-sdk # ?
    ];
  };

  systemd.services = {
    "dev-dri-ownership" = {
      wantedBy = [ "jellyfin.service" ];
      before = [ "jellyfin.service" ];
      after = [
        "dev-dri-card0.mount"
        "dev-dri-renderD128.mount"
      ];
      script = ''
        chmod 666 /dev/dri/card0
        chmod 666 /dev/dri/renderD128
      '';
      serviceConfig = {
        Type = "oneshot";
        User = "root";
      };
    };
  };

  environment.systemPackages = with pkgs; [
    vim
    libva-utils
  ];

  services.jellyfin = {
    enable = true;
    openFirewall = true;
  };

  systemd.services.jellyfin.environment = {
    JELLYFIN_FFMPEG__PROBESIZE = "30M";
  };

  nixflakes.makeUser = false;
  system.stateVersion = "24.11"; # Did you read the comment?
}
