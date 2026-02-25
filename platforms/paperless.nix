{
  pkgs,
  config,
  modulesPath,
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

  environment.systemPackages = with pkgs; [ vim ];
  nixpkgs.config.allowUnfree = true;

  networking = {
    dhcpcd.enable = false;
    useDHCP = false;
    useHostResolvConf = false;
    # Open SSH/SFTP (22) for SFTP ingest and HTTPS (443) for the web UI
    firewall.allowedTCPPorts = [ 22 443 8080 ];
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

  nixflakes.agenix.enable = true;
  age.secrets."paperless-admin-pass" = {
    file = "${private.secrets}/paperless_admin_password.txt";
  };
  age.secrets."ssl.key" = {
    file = "${private.secrets}/PT-Paperless.key";
    owner = config.services.nginx.user;
  };
  age.secrets."ssl.crt" = {
    file = "${private.secrets}/PT-Paperless.crt";
    owner = config.services.nginx.user;
  };

  services = {
    nginx = {
      virtualHosts."paperless.pleunetowne.com" = {
        sslCertificate = config.age.secrets."ssl.crt".path;
        sslCertificateKey = config.age.secrets."ssl.key".path;
        locations."/" = {
          proxyWebsockets = true;
        };
      };
    };

    paperless = {
      enable = true;
      domain = "paperless.pleunetowne.com";
      consumptionDirIsPublic = true;
      passwordFile = config.age.secrets."paperless-admin-pass".path;
      configureNginx = true;
      database.createLocally = true;
      settings = {
        PAPERLESS_OCR_USER_ARGS = {
          optimize = 1;
          pdfa_image_compression = "lossless";
        };
        PAPERLESS_URL = "https://paperless.pleunetowne.com";
        PAPERLESS_CSRF_TRUSTED_ORIGINS = "https://paperless.home.pleunetowne.com";
      };
    };
  };

  nixflakes.makeUser = false;
  system.stateVersion = "25.11";
}
