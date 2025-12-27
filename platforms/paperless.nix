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
      # enable = true;
      # recommendedProxySettings = true;
      # recommendedTlsSettings = true;
      virtualHosts."paperless.pleunetowne.com" = {
        # forceSSL = true;
        sslCertificate = config.age.secrets."ssl.crt".path;
        sslCertificateKey = config.age.secrets."ssl.key".path;
        # locations."/" = {
        #   proxyPass = "http://127.0.0.1:${toString config.services.paperless.port}";
        #   proxyWebsockets = true;
        #   extraConfig = ''
        #     client_max_body_size 50000M;
        #   '';
        # };
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
        # PAPERLESS_OCR_LANGUAGE = "deu+eng";
        PAPERLESS_OCR_USER_ARGS = {
          optimize = 1;
          pdfa_image_compression = "lossless";
        };
        PAPERLESS_URL = "https://paperless.pleunetowne.com";
        PAPERLESS_CSRF_TRUSTED_ORIGINS = "https://paperless.home.pleunetowne.com";
      };
    };
  };

  systemd.services.paperless-gpt = {
    description = "paperless-gpt (assistant / ingestion integration for Paperless)";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" "paperless.service" ];
    wants = [ "paperless.service" "network-online.target" ];
    serviceConfig = {
      User = "paperless-gpt";
      Group = "paperless-gpt";
      WorkingDirectory = config.users.users.paperless-gpt.home;
      # Use the environment file managed by agenix/age.secrets.
      #EnvironmentFile = "${config.age.secrets.\"paperless-gpt.env\".path}";
      Environment = [
        "PAPERLESS_BASE_URL=https://${config.services.paperless.domain}"
        "PAPERLESS_API_TOKEN=xxxxxx"
        "LLM_PROVIDER=openai"
        "OPENAI_BASE_URL=https://ai.pleunetowne.com/api/v1"
        "LLM_MODEL=gpt_oss_20b"
        "VISION_LLM_PROVIDER=openai"
        #"VISION_LLM_MODEL=qwen3-vl:4b"
        "VISION_LLM_MODEL=qwen2.5vl:3b"
        "OPENAI_API_KEY=sk-xxxxxx"
        "LISTEN_INTERFACE=0.0.0.0:8080"
        "PDF_UPLOAD=true"
        "TOKEN_LIMIT=1000"
        "LLM_LANGUAGE=English"
        "OCR_LIMIT_PAGES=0"
        "LOG_LEVEL=info"
        "PDF_OCR_TAGGING=true"
        "PDF_OCR_COMPLETE_TAG=paperless-gpt-ocr-complete"
        "CREATE_LOCAL_HOCR=true"
        "CREATE_LOCAL_PDF=true"
        "LOCAL_HOCR_PATH=${config.users.users.paperless-gpt.home}/hocr"
        "LOCAL_PDF_PATH=${config.users.users.paperless-gpt.home}/pdf"
        "AUTO_GENERATE_TAGS=false"
      ];
      ExecStartPre = [
        ''${pkgs.coreutils}/bin/chmod -R u+w default_prompts''
        ''${pkgs.coreutils}/bin/cp -rf ${pkgs.paperless-gpt}/default_prompts .''
      ];
      ExecStart = "${pkgs.paperless-gpt}/bin/paperless-gpt";
      Restart = "on-failure";
      RestartSec = "5s";
    };
  };

  users.groups.paperless-gpt = {};
  users.users.paperless-gpt = {
    isSystemUser = true;
    description = "Paperless-GPT service user";
    home = "/var/lib/paperless-gpt";
    createHome = true;
    group = "paperless-gpt";
  };

  nixflakes.makeUser = false;
  system.stateVersion = "25.11";
}
