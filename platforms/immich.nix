{
  pkgs,
  modulesPath,
  config,
  private,
  ...
}:

{
  imports = [
    "${modulesPath}/virtualisation/lxc-container.nix"
  ];

  environment.systemPackages = with pkgs; [
    vim
    config.boot.kernelPackages.nvidiaPackages.legacy_535.bin
    nvidia-container-toolkit
  ];
  time.timeZone = "America/Detroit";

  networking = {
    dhcpcd.enable = false;
    useDHCP = false;
    useHostResolvConf = false;
    firewall.allowedTCPPorts = [ 443 ];
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
        "immich-server.service"
        "immich-machine-learning.service"
      ];
      before = [
        "immich-server.service"
        "immich-machine-learning.service"
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
    "var-lib-immich-library-ownership" = {
      wantedBy = [
        "immich-server.service"
        "immich-machine-learning.service"
      ];
      before = [
        "immich-server.service"
        "immich-machine-learning.service"
      ];
      after = [ "var-lib-immich-library.mount" ];
      script = ''
        chown -R immich:immich /var/lib/immich/library
      '';
      serviceConfig = {
        Type = "oneshot";
        User = "root";
      };
    };
  };

  # NOTE: broken nixpkgs.config.cudaSupport = true;
  services.xserver.videoDrivers = [ "nvidia" ];
  hardware = {
    nvidia = {
      modesetting.enable = false;
      open = false;
      nvidiaSettings = false;

      # debian 12 bookworm still has only 535 instead of 550 (needed for containers)
      package = config.boot.kernelPackages.nvidiaPackages.legacy_535;
    };
    nvidia-container-toolkit.enable = true;
    graphics = {
      enable = true;
      extraPackages = with pkgs; [
        nvidia-vaapi-driver
        intel-media-driver
        vpl-gpu-rt
        libvdpau-va-gl
      ];
    };
  };

  services.immich = {
    enable = true;
    openFirewall = true;
    host = "::";
    secretsFile = "${config.services.immich.mediaLocation}/env";
  };
  users.users.immich.extraGroups = [
    "video"
    "render"
  ];

  nixflakes.agenix.enable = true;
  age.secrets."PT-Immich.key" = {
    file = "${private.secrets}/PT-Immich.key";
    owner = config.services.nginx.user;
  };
  age.secrets."PT-Immich.crt" = {
    file = "${private.secrets}/PT-Immich.crt";
    owner = config.services.nginx.user;
  };

  # TODO: issue upstream
  systemd.services."immich-server".serviceConfig.PrivateDevices = pkgs.lib.mkForce false;
  systemd.services."immich-machine-learning".serviceConfig.PrivateDevices = pkgs.lib.mkForce false;

  services.nginx = {
    enable = true;
    recommendedProxySettings = true;
    recommendedTlsSettings = true;
    virtualHosts."immich.home.pleunetowne.com" = {
      forceSSL = true;
      sslCertificate = config.age.secrets."PT-Immich.crt".path;
      sslCertificateKey = config.age.secrets."PT-Immich.key".path;
      locations."/" = {
        proxyPass = "http://127.0.0.1:${toString config.services.immich.port}";
        proxyWebsockets = true;
        extraConfig = ''
          client_max_body_size 50000M;
        '';
      };
    };
  };

  nixflakes.makeUser = false;
  system.stateVersion = "24.11";
}
