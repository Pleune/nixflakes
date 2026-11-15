{
  username,
  config,
  lib,
  pkgs,
  modulesPath,
  hermes-agent,
  hermes-webui,
  ...
}:

{
  boot.initrd.availableKernelModules = [
    "nvme"
    "ahci"
    "xhci_pci"
    "usbhid"
    "usb_storage"
    "sd_mod"
  ];
  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [ "kvm-amd" ];
  boot.extraModulePackages = [ ];

  fileSystems."/" = {
    device = "/dev/disk/by-uuid/0ac80936-993e-4ab4-ac9f-c36b5684e63a";
    fsType = "ext4";
  };

  fileSystems."/boot" = {
    device = "/dev/disk/by-uuid/7775-3329";
    fsType = "vfat";
    options = [
      "fmask=0077"
      "dmask=0077"
    ];
  };

  swapDevices = [
    { device = "/dev/disk/by-uuid/0dd11fcf-bf0d-414c-9749-a326503086fb"; }
  ];

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
  hardware.cpu.amd.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;

  # Use the systemd-boot EFI boot loader.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  imports = [
    # Hermes Agent and Hermes WebUI, both consumed below.  Imported here rather than in
    # config/nixos because only this host runs them.
    hermes-agent.nixosModules.default
    hermes-webui.nixosModules.default
  ];

  networking.networkmanager.enable = true;
  time.timeZone = "America/Detroit";
  i18n.defaultLocale = "en_US.UTF-8";
  i18n.extraLocaleSettings = {
    LC_ADDRESS = "en_US.UTF-8";
    LC_IDENTIFICATION = "en_US.UTF-8";
    LC_MEASUREMENT = "en_US.UTF-8";
    LC_MONETARY = "en_US.UTF-8";
    LC_NAME = "en_US.UTF-8";
    LC_NUMERIC = "en_US.UTF-8";
    LC_PAPER = "en_US.UTF-8";
    LC_TELEPHONE = "en_US.UTF-8";
    LC_TIME = "en_US.UTF-8";
  };

  # Configure keymap in X11
  services.xserver.xkb = {
    layout = "us";
    variant = "";
  };

  nixpkgs.config.allowUnfree = true;

  # Enable graphics
  hardware.graphics = {
    enable = true;
    enable32Bit = true;
  };

  # NVIDIA driver
  services.xserver.videoDrivers = [
    "nvidia"
    "amdgpu"
  ];

  hardware.nvidia = {
    open = false;
    package = config.boot.kernelPackages.nvidiaPackages.stable;

    # no desktop stuff
    modesetting.enable = false;
    nvidiaSettings = false;

    # prime = {
    #   offload = {
    #     enable = true;
    #     enableOffloadCmd = true;
    #   };
    #
    #   nvidiaBusId = "PCI:1:0:0";
    #   amdgpuBusId = "PCI:5:0:0";
    # };
  };

  environment.systemPackages = with pkgs; [
    cudaPackages.cudatoolkit
    # (lib.getBin config.hardware.nvidia.package)
    pciutils
    nvtopPackages.full
  ];

  services.openssh.enable = true;

  # The firewall is set once, below next to the Strata service that opens 8080 through
  # `openFirewall`; a second `networking.firewall` assignment here would be an eval error.

  # Copy the NixOS configuration file and link it from the resulting system
  # (/run/current-system/configuration.nix). This is useful in case you
  # accidentally delete configuration.nix.
  # system.copySystemConfiguration = true;

  # Strata: the local OpenAI/Anthropic-compatible inference server for Qwen3.8-Flash-Next.
  # This is the box the GPU lives in, so this is where the engine runs and where the llm
  # platform's hermes hooks point.
  #
  # Gyro-M (agentionai's Hadamard-folded Qwen3.8-Flash-Next, TQ2_0) is served on 131072 tokens
  # with int8 KV, matching the config used by hand before this service existed.  The quant is one
  # ~86 GB file: the first start downloads it and builds the pack (`iq_pack.py --compat-bf16`), so
  # the unit has no start timeout and the first converge after a deploy is slow.  Everything else
  # (expert cache, prefill, MTP draft layer, kv-resident) is derived by strata-prefetch and written
  # to /var/lib/strata/config.json, the same as Strata's own setup.sh does.
  #
  # Vision stays on the CPU: the GPU image encoder would keep ~1.4 GB of VRAM off the expert arena.
  nixflakes.services.strata = {
    enable = true;
    cudaArch = "86";
    family = "gyro";
    model = "Gyro-M";
    context = 131072;
    kv = "int8";
    port = 8080;
    vision = "cpu";
    gpus = [ "0" ];

    # Served to the LAN without an API key, so it is reachable by the llm host (and anything else
    # on PleuneNET).  `openFirewall` adds 8080 to the firewall, which is on for this host now.
    host = "0.0.0.0";
    allowUnauthenticated = true;
    openFirewall = true;

    # The server only answers to host names it knows; the domain the llm host (and Hermes) will
    # call has to be named here or the request comes back 403.
    allowedHosts = [ "ai.home.pleunetowne.com" ];

    # First start of the unit downloads about 92 GB into /var/lib/strata and builds the pack, which
    # takes a while (TimeoutStartSec is 0 so systemd does not kill it).  The old copy under
    # ~/Strata-data belongs to the installer-run server and is not read by the unit.
    #
    # `tune` is on by default and adds the other half of that first start: Strata's own setup.py
    # measures --pcie-frac, --spec-min-p, --pool-workers, --adapt-every/--adapt-swaps/--adapt-decay
    # (and --prefill-pipe for a layer split) per PC with tools/calibrate.py, roughly 15-30 minutes,
    # and Nix never runs setup.py.  Without it this box serves the same model on settings measured
    # on the authors' hardware.  The measurement starts the engine itself, so nothing else may hold
    # the GPU during that first start; it lands in /var/lib/strata/tune.json and is replayed into
    # config.json on every later start.  `tuneForce = true` re-measures at the next start.
    tune = true;

    # The engine saves the expert tier it learns while serving to
    # /var/lib/strata/expert-profile-learned-gyrom.bin (every 10 minutes and on quit) and begins the
    # next start from it when it is a profile of this model, instead of the package's
    # data/gyro-expert-profile.bin, which was measured on someone else's traffic.
    learnExpertProfile = true;
    learnProfileEvery = 10;
  };

  # Hermes Agent, hosted here for now (temporarily moved off llm; see the disabled block in
  # platforms/llm.nix — restore it there to move Hermes back).
  #
  # Container mode: the gateway runs as an Ubuntu 24.04 container (docker, auto-enabled by the
  # module) with /nix/store bind-mounted read-only and /var/lib/hermes mounted at /data, so apt/
  # pip/npm self-modification persists in the writable layer across restarts and rebuilds.  The
  # container uses --network=host, which is what makes the API server below visible on the LAN.
  #
  # The `hermes dashboard` hashboard cannot run in container mode (the module asserts against it:
  # the container runs the gateway only), so the browser UI here is Hermes WebUI, configured below.
  # The gateway's OpenAI-compatible API server on 8642 is still on: it is the LAN endpoint for other
  # clients, and Hermes WebUI's Tasks/cron health probe polls it.
  services.hermes-agent = {
    enable = true;
    container.enable = true;

    # `hermes` on the system PATH plus HERMES_HOME exported system-wide; the host CLI reads
    # /var/lib/hermes/.hermes/.container-mode and execs into the container, so interactive shells
    # share sessions, skills and cron with the service instead of growing a second ~/.hermes.
    addToSystemPackages = true;

    # Mitch gets ~/.hermes -> /var/lib/hermes/.hermes and joins the hermes group.
    container.hostUsers = [ username ];

    # Plaintext for now; the agenix pass moves these to an environmentFile / age secret.
    #
    # API_SERVER_KEY is mandatory: the api_server platform refuses to start without it (and
    # checks its strength).  It authenticates every /v1 request as a bearer token, which is what
    # lets the API server answer the whole LAN.
    environment = {
      API_SERVER_KEY = "hermes-lan-bootstrap";
    };

    settings = {
      # The model is Strata on this very box (nixflakes.services.strata above), reached through
      # its LAN name: Strata answers only to host names it knows, and
      # ai.home.pleunetowne.com resolves locally here, so the traffic never leaves the machine.
      providers.strata = {
        api = "http://ai.home.pleunetowne.com:8080/v1";
        transport = "chat_completions";
        default_model = "qwen3.8-flash-next-gyro-gyro-m"; # the id strata-prefetch writes into config.json
        context_length = 131072; # what ai serves; Hermes refuses to start below 64000
        session_affinity_header = "x-strata-session"; # Strata holds one KV cache per conversation
      };

      # `custom:<name>` is the durable identity of a `providers:` entry, so this picks the entry
      # above instead of the bare "custom" class, and the endpoint shows up under its own name in
      # `hermes model`.  Gyro-M is the only model.
      model = {
        provider = "custom:strata";
        default = "qwen3.8-flash-next-gyro-gyro-m";
        context_length = 131072;
      };

      # The gateway's OpenAI-compatible API server (gateway/platforms/api_server.py): /v1/chat/
      # completions, /v1/responses, /v1/models, /health.  config.yaml keys beat the env fallbacks
      # (API_SERVER_HOST/API_SERVER_PORT).  network=host + 0.0.0.0 puts it on the LAN; the
      # bearer key above is the gate, and the firewall below opens 8642.
      platforms.api_server = {
        enabled = true;
        extra.host = "0.0.0.0";
        extra.port = 8642;
      };

      terminal.backend = "local"; # the container itself is the sandbox
      compression.enabled = true;
    };

    # backend.mode must stay "none": the module refuses serve/dashboard together with
    # container.enable (one command in one container).  Hermes WebUI replaces the hashboard.
  };

  # Hermes WebUI (github:nesquena/hermes-webui — not in nixpkgs, but it ships its own package and
  # NixOS module, so this is the clean path).  This replaces the hashboard that container mode
  # cannot run.
  #
  # Chat is routed to the gateway container rather than to the WebUI's own in-process runtime
  # (`HERMES_WEBUI_CHAT_BACKEND = gateway`, docs/advanced-chat-setup.md): with `container.enable`
  # the agent already runs in the container against /var/lib/hermes/.hermes, and a second
  # in-process agent would race it on the same state.db.  The WebUI still reads
  # $HERMES_HOME/config.yaml for its model list and session view, so it shows exactly the config
  # above — Gyro-M through Strata — and the browser talks to the same gateway the CLI does.
  # Gateway mode costs a few WebUI-only routes, which answer 409 `gateway_mode_unsupported`:
  # /api/btw, /api/background, /api/session/compress*, the non-streaming /api/chat fallback,
  # /api/updates/summary and the git commit-message helpers.
  services.hermes-webui = {
    enable = true;

    # LAN-facing.  A non-loopback bind REQUIRES HERMES_WEBUI_PASSWORD: without it anyone who can
    # reach the port runs agent commands.  Plaintext for now, with the rest of the credentials;
    # the agenix pass moves it to an environmentFile (the module rejects protected runtime keys
    # there, but a password is an ordinary entry).
    host = "0.0.0.0";
    port = 8787; # module default; 8080/8642 are Strata and the gateway here
    openFirewall = true;

    # Read the agent's own state instead of growing a second ~/.hermes.  The module never changes
    # ownership of an existing hermesHome, so the service runs as the Hermes account, which can
    # already read /var/lib/hermes.
    user = "hermes";
    group = "hermes";
    hermesHome = "/var/lib/hermes/.hermes"; # = the agent module's stateDir/.hermes
    stateDir = "/var/lib/hermes/.hermes/webui"; # module default would be /var/lib/hermes-webui

    # Same package the service runs, so the in-process agent gets Hermes' own venv: the module
    # reads passthru.hermesVenv for HERMES_WEBUI_PYTHON.  hermes-agent exposes no
    # passthru.hermesAgentDir, so the agent root comes from that interpreter's
    # `find_spec("run_agent")` probe (hermes-webui api/startup.py:_agent_dir_from_python).
    agent.package = config.services.hermes-agent.package;

    extraEnvironment = {
      # Browser turns go to the gateway's API server.  `--network=host` means the container's
      # 0.0.0.0:8642 is also 127.0.0.1:8642 for this unit, so the WebUI talks to the gateway over
      # loopback and never through the firewall.
      HERMES_WEBUI_CHAT_BACKEND = "gateway";
      HERMES_WEBUI_GATEWAY_BASE_URL = "http://127.0.0.1:8642";
      # Approval cards need the gateway runs API (/v1/runs + /v1/runs/{id}/approval).  The pinned
      # hermes-agent advertises it (gateway/platforms/api_server.py:51
      # `run_approval_response: true`, `approval_events: true`); drop this line if a future agent
      # stops advertising approval support, and gateway chat falls back to chat-completions.
      HERMES_WEBUI_GATEWAY_USE_RUNS_API = "true";

      # The agent dir resolves inside the read-only store, so relative writes need a writable
      # home; this is the workspace the container mounts at /data/workspace.
      HERMES_WEBUI_SERVER_CWD = "/var/lib/hermes/workspace";
      HERMES_WEBUI_DEFAULT_WORKSPACE = "/var/lib/hermes/workspace";
      HERMES_WEBUI_SKIP_ONBOARDING = "1"; # config.yaml is declarative; no first-run wizard
      # Same key the gateway was given, so the WebUI authenticates to it (and health-probes it).
      HERMES_WEBUI_GATEWAY_API_KEY = "hermes-lan-bootstrap";
      HERMES_WEBUI_PASSWORD = "hermes-lan-bootstrap"; # agenix pass
    };
  };

  # Firewall on, for the sake of the model endpoint above.  openssh opens 22 itself, and Strata
  # opens 8080 through openFirewall; mDNS stays reachable because nixflakes.network.mdns is
  # enabled on every host and avahi answers on UDP 5353.
  #
  # Hermes adds the LAN surface: 8642 is the gateway API server (bearer-key gated by
  # API_SERVER_KEY).  Hermes WebUI opens its own 8787 through openFirewall above, so it is not
  # listed here; this stays the file's only `networking.firewall` assignment.
  networking.firewall = {
    enable = true;
    allowedTCPPorts = [ 8642 ];
    allowedUDPPorts = [ 5353 ];
  };

  users.users.${username}.extraGroups = [
    "video"
    "render"
  ];

  system.stateVersion = "26.05"; # Did you read the comment?
}
