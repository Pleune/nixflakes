{
  pkgs,
  modulesPath,
  config,
  private,
  hermes-agent,
  ...
}:
let
  # needs to match nas host
  nvidia_x11 = pkgs.linuxPackages.nvidia_x11_legacy535;
in
{
  imports = [
    "${modulesPath}/virtualisation/lxc-container.nix"
    # Hermes Agent's NixOS module.  Imported here, and not in config/nixos, because Hermes runs on
    # this host alone.
    hermes-agent.nixosModules.default
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
  services.tika = {
    enable = true;
    port = 9998;
  };
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

      CONTENT_EXTRACTION_ENGINE = "tika";
      TIKA_SERVER_URL = "http://localhost:9998";
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

  # Hermes Agent, hosted here: the `hermes` CLI on the system PATH, its state under
  # /var/lib/hermes/.hermes (the module default stateDir), and `hermes serve` on 127.0.0.1:9119 for
  # Hermes Desktop and anything else that wants the /api/ws + /api/pty sockets.
  #
  # The model itself is not here.  It is Strata on ai (nixflakes.services.strata in platforms/ai.nix),
  # reached over the LAN.
  services.hermes-agent = {
    enable = true;

    # `hermes` on environment.systemPackages, plus HERMES_HOME exported system-wide, so an
    # interactive shell shares sessions, skills and cron with the units instead of keeping a
    # second ~/.hermes.
    addToSystemPackages = true;

    settings = {
      # Strata answers only to host names it knows (platforms/ai.nix allows
      # "ai.home.pleunetowne.com"), so name it rather than using a LAN address, and it runs with
      # allowUnauthenticated, so no api_key: Hermes sends its "no-key-required" placeholder to a
      # keyless server.
      #
      # Strata holds one KV cache per conversation.  session_affinity_header makes Hermes carry the
      # conversation id on every request, so a later turn reuses that cache instead of re-prefilling
      # the history.
      providers.strata = {
        api = "http://ai.home.pleunetowne.com:8080/v1";
        transport = "chat_completions";
        default_model = "qwen3.8-flash-next-gyro-gyro-m"; # the id strata-prefetch writes into config.json
        context_length = 131072; # what ai serves; Hermes refuses to start below 64000
        session_affinity_header = "x-strata-session";
      };

      # `custom:<name>` is the durable identity of a `providers:` entry, so this picks the entry
      # above instead of the bare "custom" class, and the endpoint shows up under its own name in
      # `hermes model`.
      model = {
        provider = "custom:strata";
        default = "qwen3.8-flash-next-gyro-gyro-m";
        context_length = 131072;
      };

      terminal.backend = "local"; # the agent runs on this host, not in a sandbox
      compression.enabled = true;
    };

    backend = {
      # `hermes serve`: the API without the browser admin panel.  The gateway unit comes along with
      # enable and stays up without messaging platforms (cron only), so nothing needs credentials.
      mode = "serve";
      port = 9119;
      # host stays the module default, 127.0.0.1.  Any other address switches on the dashboard
      # auth gate, which needs backend.sessionTokenFile pointing at an agenix-managed file; that is
      # a later change.  Reach it today with an ssh tunnel to llm.
    };
  };

  users.users.${config.services.ollama.user}.extraGroups = [
    "video"
    "render"
  ];

  nixflakes.makeUser = false;
  system.stateVersion = "24.11";
}
