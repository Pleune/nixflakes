{
  pkgs,
  modulesPath,
  config,
  lib,
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
    #vim
    #sqlite
    #open-webui
    #apacheHttpd # for password reset htpassword command
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
      # The Hermes dashboard, reached from a browser on the LAN.  Off while Hermes runs on ai
      # (see the disabled block below); uncomment to move it back.
      # 9119
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
        #"ollama.service"
      ];
      before = [
        #"ollama.service"
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

  # services.ollama = {
  #   enable = true;
  #
  #   # open up for trilium
  #   host = "0.0.0.0";
  #   openFirewall = true;
  # };
  # services.tika = {
  #   enable = true;
  #   port = 9998;
  # };
  # services.docling-serve = {
  #   enable = false; # FIXME: marked broken
  #   port = 8082;
  #   package = pkgs.docling-serve.override {
  #     #withUI = true;
  #     #withRapidocr = true;
  #     #withTesserocr = true;
  #     withCPU = true;
  #   };
  #   environment = {
  #     DOCLING_SERVE_ENABLE_UI = "False";
  #     DOCLING_SERVE_ENABLE_REMOTE_SERVICES = "True";
  #     DOCLING_SERVE_LOAD_MODELS_AT_BOOT = "False";
  #
  #     # TODO: remove https://github.com/NixOS/nixpkgs/issues/411914#issuecomment-2917861802
  #     HOME = "/var/lib/docling-serve";
  #   };
  #   openFirewall = true;
  # };
  # services.searx = {
  #   enable = true;
  #   settings.server = {
  #     port = 8081;
  #     secret_key = "superdupersecret";
  #     bind_address = "0.0.0.0";
  #   };
  #   settings.search.formats = [
  #     "json"
  #     "html"
  #   ];
  # };

  # services.open-webui = {
  #   enable = true;
  #   host = "0.0.0.0";
  #   openFirewall = true;
  #   environment = {
  #     ENABLE_WEB_SEARCH = "True";
  #     WEB_SEARCH_ENGINE = "searxng";
  #     WEB_SEARCH_RESULT_COUNT = "3";
  #     WEB_SEARCH_CONCURRENT_REQUESTS = "10";
  #     SEARXNG_QUERY_URL = "http://localhost:8081/search?q=<query>";
  #
  #     CONTENT_EXTRACTION_ENGINE = "tika";
  #     TIKA_SERVER_URL = "http://localhost:9998";
  #     DOCLING_OCR_ENGINE = "tesserocr";
  #     DOCLING_OCR_LANG = "eng";
  #     DOCLING_SERVER_URL = "http://localhost:8082";
  #
  #
  #     # TODO: remove https://github.com/NixOS/nixpkgs/issues/411914#issuecomment-2917861802
  #     HOME = "/var/lib/open-webui";
  #   };
  # };

  # The origional author removed this from github :(
  #nixflakes.services.wake-on-lan-api = {
  #  enable = true;
  #  port = 8083;
  #};

  # Hermes Agent, hosted here: the `hermes` CLI on the system PATH, its state under
  # /var/lib/hermes/.hermes (the module default stateDir), and `hermes dashboard` on 0.0.0.0:9119 for
  # the browser admin panel plus the /api/ws + /api/pty sockets.
  #
  # CURRENTLY DISABLED: Hermes runs on ai in container mode with Hermes WebUI instead of the
  # hashboard here (see platforms/ai.nix).  The whole block is kept intact so moving back is one
  # `enable` flip plus the two 9119 firewall lines.
  #
  # The model itself is not here.  It is Strata on ai (nixflakes.services.strata in platforms/ai.nix),
  # reached over the LAN.
  services.hermes-agent = {
    enable = false;
    container.enable = true;

    # Stamp a real release version onto the package.  Upstream's `pyproject.toml` carries
    # `version = "0.0.0"` and the Nix package defaults to that, so the CLI reports Hermes 0.0.0 and
    # every gate keyed on it fails: `hermes plugins install` refuses anything whose manifest says
    # `requires_hermes >=0.22.0` ("needs Hermes >=0.22.0; this is 0.0.0"), and the plugin update feed
    # gates the same way.  `version` is the only input to that check
    # (hermes_cli/plugins_manifest.py `running_hermes_version` reads the stamp's `baseVersion`), and
    # the gate truncates at the first `+`, so a local suffix is harmless.
    #
    # Values are the release the pinned input sits on: `git describe --tags` in the hermes-agent
    # checkout gives `v0.23.1+canary.20261112T064528Z-1263-gf3477069fa`, i.e. 1263 commits past the
    # v0.23.1 tag.  Update both numbers whenever the flake input moves.
    # package = hermes-agent.packages.${pkgs.stdenv.hostPlatform.system}.default.override {
    #   version = "0.23.1";
    #   distance = 1263;
    # };

    # Dashboard login.  Hermes reads these before config.yaml — env wins — hashes the password in
    # memory at each start and never puts it in config.yaml.  They land in $HERMES_HOME/.env, mode
    # 0640, owned by `hermes`; the plaintext also sits in this file and therefore in the nix store,
    # so the next step is to source them from an agenix env file.
    #
    # Because env beats config.yaml, changing the password on the box does nothing while these are
    # set: rotate it here and rebuild, or drop the password line and let
    # dashboard.basic_auth.password_hash take over.
    #
    # secret signs the session tokens; without a fixed value every restart mints a fresh key and
    # logs everyone out.  It must decode to 16+ bytes (base64 or hex).
    environment = {
      HERMES_DASHBOARD_BASIC_AUTH_USERNAME = "mitch";
      HERMES_DASHBOARD_BASIC_AUTH_PASSWORD = "hermes-bootstrap";
      HERMES_DASHBOARD_BASIC_AUTH_SECRET = "2W74lj6sTnRABgmlKGNN4SGqIzgvwExq6YP70XmE5z0=";
    };

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
      # `hermes dashboard`: the /api/ws + /api/pty sockets and the browser admin panel on the same
      # port.  The gateway unit comes along with enable and stays up without messaging platforms
      # (cron only), so nothing needs credentials.
      #mode = "dashboard";
      host = "0.0.0.0";
      port = 9119;
      # Binding a non-loopback address switches on the auth gate, and 0.0.0.0 accepts any Host
      # header.  The gate is satisfied by the `basic` provider the environment block above
      # registers — nothing needs to be written to config.yaml.
    };
  };

  # Paired with the disabled Hermes block above; uncomment together with `enable = true`.
  # networking.firewall.allowedTCPPorts = [ 9119 ];

  # users.users.${config.services.ollama.user}.extraGroups = [
  #   "video"
  #   "render"
  # ];

  nixflakes.makeUser = false;
  system.stateVersion = "24.11";
}
