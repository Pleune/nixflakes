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

  environment.systemPackages = with pkgs; [ vim ];
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
        chgrp video /dev/dri/card0
        chgrp render /dev/dri/renderD128
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
