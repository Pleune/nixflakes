{
  pkgs,
  modulesPath,
  config,
  private,
  ...
}:
let
  # needs to match nas host
  nvidia_x11 = pkgs.linuxPackages.nvidia_x11_legacy535;
in
{
  imports = [
    "${modulesPath}/virtualisation/lxc-container.nix"
  ];

  nixpkgs = {
    hostPlatform = {
      #breaks ollama
      # gcc.arch = "alderlake";
      # gcc.tune = "alderlake";
      system = "x86_64-linux";
    };
    config.cudaSupport = true;
  };

  environment.systemPackages = with pkgs; [
    vim
    #nvidia_x11.bin
  ];
  time.timeZone = "America/Detroit";

  networking = {
    dhcpcd.enable = false;
    useDHCP = false;
    useHostResolvConf = false;
    firewall.allowedTCPPorts = [ 443 8081 ];
  };

  systemd.network = {
    enable = true;
    networks."50-eth0" = {
      matchConfig.Name = "eth0";
      networkConfig = {
        DHCP = "ipv4";
        IPv6AcceptRA = true;
      };
      linkConfig.RequiredForOnline = "routable";
    };
  };

  systemd.services = {
    "dev-dri-ownership" = {
      wantedBy = [
        "ollama.service"
      ];
      before = [
        "ollama.service"
      ];
      after = [
        "dev-dri-card0.mount"
        "dev-dri-renderD128.mount"
      ];
      script = ''
        chgrp video /dev/dri/card*
        chgrp render /dev/dri/renderD*
      '';
      serviceConfig = {
        Type = "oneshot";
        User = "root";
      };
    };
  };

  hardware = {
    graphics = {
      enable = true;
      extraPackages = with pkgs; [
        intel-media-driver
        libvdpau-va-gl
        nvidia-vaapi-driver
        nvidia_x11.out
        vpl-gpu-rt
      ];
    };
  };

  services.ollama.enable = true;
  services.tika.enable = true;
  services.searx = {
    enable = true;
    settings.server = {
      port = 8081;
    secret_key = "superdupersecret";
    bind_address = "0.0.0.0";
    };
    settings.search.formats = [ "json" "html" ];
  };

  services.open-webui = {
    enable = true;
    host = "0.0.0.0";
    openFirewall = true;
  };

  users.users.${config.services.ollama.user}.extraGroups = [
    "video"
    "render"
  ];

  nixflakes.makeUser = false;
  system.stateVersion = "24.11";
}
