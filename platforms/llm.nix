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
    sqlite
    open-webui
    apacheHttpd # for password reset htpassword command
    #nvidia_x11.bin
  ];
  time.timeZone = "America/Detroit";

  networking = {
    dhcpcd.enable = false;
    useDHCP = false;
    useHostResolvConf = false;
    firewall.allowedTCPPorts = [
      443
      8081
    ];
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

  services.ollama = {
    enable = true;

    # open up for trilium
    host = "0.0.0.0";
    openFirewall = true;
  };
  #services.tika.enable = true;
  services.docling-serve = {
    enable = false; # FIXME: marked broken
    port = 8082;
    package = pkgs.docling-serve.override {
      #withUI = true;
      #withRapidocr = true;
      #withTesserocr = true;
      withCPU = true;
    };
    environment = {
      DOCLING_SERVE_ENABLE_UI = "False";
      DOCLING_SERVE_ENABLE_REMOTE_SERVICES = "True";
      DOCLING_SERVE_LOAD_MODELS_AT_BOOT = "False";

      # TODO: remove https://github.com/NixOS/nixpkgs/issues/411914#issuecomment-2917861802
      HOME = "/var/lib/docling-serve";
    };
    openFirewall = true;
  };
  services.searx = {
    enable = true;
    settings.server = {
      port = 8081;
      secret_key = "superdupersecret";
      bind_address = "0.0.0.0";
    };
    settings.search.formats = [
      "json"
      "html"
    ];
  };

  services.open-webui = {
    enable = true;
    host = "0.0.0.0";
    openFirewall = true;
    environment = {
      ENABLE_WEB_SEARCH = "True";
      WEB_SEARCH_ENGINE = "searxng";
      WEB_SEARCH_RESULT_COUNT = "3";
      WEB_SEARCH_CONCURRENT_REQUESTS = "10";
      SEARXNG_QUERY_URL = "http://localhost:8081/search?q=<query>";

      CONTENT_EXTRACTION_ENGINE = "docling";
      DOCLING_OCR_ENGINE = "tesserocr";
      DOCLING_OCR_LANG = "eng";
      DOCLING_SERVER_URL = "http://localhost:8082";

      # TODO: remove https://github.com/NixOS/nixpkgs/issues/411914#issuecomment-2917861802
      HOME = "/var/lib/open-webui";
    };
  };
  
  nixflakes.services.wake-on-lan-api = {
    enable = true;
    port = 8083;
  };

  users.users.${config.services.ollama.user}.extraGroups = [
    "video"
    "render"
  ];

  nixflakes.makeUser = false;
  system.stateVersion = "24.11";
}
