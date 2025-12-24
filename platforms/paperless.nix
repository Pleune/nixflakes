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
    firewall.allowedTCPPorts = [ 22 443 ];
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
    #owner = config.services.paperless.user;
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
      enable = true;
      recommendedProxySettings = true;
      recommendedTlsSettings = true;
      virtualHosts."paperless.pleunetowne.com" = {
        forceSSL = true;
        sslCertificate = config.age.secrets."ssl.crt".path;
        sslCertificateKey = config.age.secrets."ssl.key".path;
        locations."/" = {
          proxyPass = "http://127.0.0.1:${toString config.services.paperless.port}";
          proxyWebsockets = true;
          extraConfig = ''
            client_max_body_size 50000M;
          '';
        };
      };
    };

    paperless = {
      enable = true;
      consumptionDirIsPublic = true;
      passwordFile = config.age.secrets."paperless-admin-pass".path;
      settings = {
        # PAPERLESS_OCR_LANGUAGE = "deu+eng";
        PAPERLESS_OCR_USER_ARGS = {
          optimize = 1;
          pdfa_image_compression = "lossless";
        };
        PAPERLESS_URL = "https://paperless.pleunetowne.com";
        PAPERLESS_CSRF_TRUSTED_ORIGINS = "https://paperless.home.pleunetowne.com";
      };
    };

    # Enable OpenSSH so we can provide an SFTP ingest endpoint.
    # We restrict the ingest user to internal-sftp and a chrooted directory.
    openssh = {
      enable = true;
      permitRootLogin = "no";
      # Keep global password auth disabled for security; we enable it only
      # for the Match block below so an admin can set a local password if desired.
      passwordAuthentication = false;
      extraConfig = ''
        Subsystem sftp internal-sftp

        Match User paperless-sftp
          ChrootDirectory /var/lib/paperless/consume/sftp
          ForceCommand internal-sftp
          # Allow password auth for this Match so the operator can set a password
          # If you prefer key-based auth, remove or change this and configure keys.
          PasswordAuthentication yes
          AllowTcpForwarding no
          X11Forwarding no
      '';
    };
  };

  # Local system user for SFTP ingest into the Paperless consumption directory.
  # This user is restricted to SFTP via the sshd Match block above.
  users.users.paperless-sftp = {
    isSystemUser = true;
    description = "Paperless SFTP ingest user";
    # We do not create a writable home here because for a chroot the top-level
    # chroot directory must be owned by root. The actual incoming directory is
    # owned by the Paperless user so Paperless can consume uploaded files.
    createHome = false;
    home = "/var/lib/paperless/consume/sftp";
    # Put the user in the same group as the paperless service user so uploaded
    # files can be read/consumed. The paperless module defines its user name at
    # `config.services.paperless.user`.
    extraGroups = [ config.services.paperless.user ];
    # Do not set a password here; set it securely on the machine (or use keys).
  };

  # Ensure the consumption directories exist with the correct ownership/permissions.
  # The chroot directory must be owned by root and not writable by others.
  # The inner directory is owned by the paperless user so it can consume files.
  systemd.tmpfiles.rules = [
    # ensure base consumption dir exists and owned by paperless
    "d /var/lib/paperless/consume 0750 ${toString config.services.paperless.user} ${toString config.services.paperless.user} - -"
    # chroot dir must be owned by root (required by OpenSSH), not writable by others
    "d /var/lib/paperless/consume/sftp 0751 root ${toString config.services.paperless.user} - -"
    # place an 'incoming' directory writable by the paperless user
    "d /var/lib/paperless/consume/sftp/incoming 0750 ${toString config.services.paperless.user} ${toString config.services.paperless.user} - -"
  ];

  nixflakes.makeUser = false;
  system.stateVersion = "25.11";
}
