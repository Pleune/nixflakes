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

  nixflakes.agenix.enable = true;
  age.secrets."nextcloud-admin-pass" = {
    file = "${private.secrets}/nextcloud_admin_password.txt";
    owner = "nextcloud";
  };
  age.secrets."ssl.key" = {
    file = "${private.secrets}/PT-Nextcloud.key";
    owner = config.services.nginx.user;
  };
  age.secrets."ssl.crt" = {
    file = "${private.secrets}/PT-Nextcloud.crt";
    owner = config.services.nginx.user;
  };

  services = {
    nginx = {
      virtualHosts."cloud.pleunetowne.com" = {
        forceSSL = true;
        sslCertificate = config.age.secrets."ssl.crt".path;
        sslCertificateKey = config.age.secrets."ssl.key".path;
      };
    };

    nextcloud = {
      enable = true;
      hostName = "cloud.pleunetowne.com";

      # Need to manually increment with every major upgrade.
      package = pkgs.nextcloud31;

      database.createLocally = true;
      maxUploadSize = "200G";
      https = true;
      appstoreEnable = true;
      # extraApps = with config.services.nextcloud.package.packages.apps; {
      #   inherit
      #     calendar
      #     contacts
      #     mail
      #     notes
      #     tasks
      #     previewgenerator
      #     cookbook
      #     bookmarks
      #     cospend
      #     deck
      #     ;
      #
      #   # Custom app installation example.
      #   #cookbook = pkgs.fetchNextcloudApp rec {
      #   #  url =
      #   #    "https://github.com/nextcloud/cookbook/releases/download/v0.10.2/Cookbook-0.10.2.tar.gz";
      #   #  sha256 = "sha256-XgBwUr26qW6wvqhrnhhhhcN4wkI+eXDHnNSm1HDbP6M=";
      #   #};
      # };

      configureRedis = true;
      settings = {
        overwriteProtocol = "https";
        trusted_domains = [
          "nextcloud.home.pleunetowne.com"
          "cloud.pleunetowne.com"
        ];
        defaultPhoneRegion = "US";
      };

      config = {
        dbtype = "pgsql";
        adminpassFile = config.age.secrets."nextcloud-admin-pass".path;
      };
    };
  };

  systemd.services = {
    "media-ownership" = {
      wantedBy = [ "nextcloud-setup.service" ];
      before = [ "nextcloud-setup.service" ];
      script = ''
        chown nextcloud:nextcloud /media
      '';
      serviceConfig = {
        Type = "oneshot";
        User = "root";
      };
    };
  };

  nixflakes.makeUser = false;
  system.stateVersion = "24.11"; # Did you read the comment?
}
