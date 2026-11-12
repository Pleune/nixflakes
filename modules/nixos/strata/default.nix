# Strata as a service: `strata.service` runs strata-prefetch in preStart (download, verify, pack,
# write config.json) and strata-serve against that config.  Packages, pins, checks and the model
# tables live in ../../../pkgs/strata/README.md.
{
  config,
  lib,
  pkgs,
  ...
}:
with lib;
let
  cfg = config.nixflakes.services.strata;
in
{
  options.nixflakes.services.strata = {
    enable = mkEnableOption "Strata, a local OpenAI/Anthropic-compatible API for Qwen3.8-Flash-Next (125B MoE)";

    cudaArch = mkOption {
      type = types.str;
      default = "86";
      example = "120";
      description = ''
        CUDA architecture the engine and the vision encoder are compiled for, as a plain number:
        "86" for Ampere (RTX 3070/3090), "120" for Blackwell (RTX 5090).  Changing it changes
        `package`, so the whole engine is rebuilt.
      '';
    };

    package = mkOption {
      type = types.package;
      default = pkgs.strata.override {
        engine = pkgs.strata-engine.override { cudaArch = cfg.cudaArch; };
        vision = pkgs.strata-vision.override { cudaArch = cfg.cudaArch; };
      };
      defaultText = literalExpression ''
        pkgs.strata.override {
          engine = pkgs.strata-engine.override { cudaArch = cfg.cudaArch; };
          vision = pkgs.strata-vision.override { cudaArch = cfg.cudaArch; };
        }
      '';
      description = "The strata bundle (server + prefetch + engine/encoder through passthru).";
    };

    family = mkOption {
      type = types.enum [
        "qwen"
        "swift"
        "abliterated"
        "coder"
        "gyro"
      ];
      default = "swift";
      description = ''
        Which model: `swift` (Swift 1.5, answers about 1.8x sooner for the same accuracy),
        `abliterated` (Swift 1.5 uncensored, SC117's re-quant; Q2_0/IQ2_XS/IQ3_XXS),
        `qwen` (the original Qwen3.8-Flash-Next), `coder` (half the experts kept, code-focused)
        or `gyro` (agentionai's Hadamard-folded variant; ships one file per size, so its
        `model` values are the size names `Gyro-S`/`Gyro-M` rather than quant names).
      '';
    };

    model = mkOption {
      type = types.enum [
        "Q2_0"
        "IQ2_XS"
        "IQ3_XXS"
        "IQ3_S"
        "IQ1_M"
        "Gyro-S"
        "Gyro-M"
      ];
      default = "IQ2_XS";
      description = ''
        Quantization size: Q2_0 (fastest), IQ2_XS (recommended), IQ3_XXS (better, slower),
        IQ3_S (best, qwen only, about 62 GB RAM), IQ1_M (coder only, about 32 GB RAM).
        Gyro sizes instead: Gyro-S (TQ1_0, about 28 GB of GPU + system memory) and Gyro-M
        (TQ2_0, about 35 GB) - the only two it publishes, and they need `family = "gyro"`.
      '';
    };

    context = mkOption {
      type = types.enum [
        8192
        32768
        65536
        131072
        204800
        262144
        393216
        524288
        786432
        1048576
      ];
      default = 32768;
      description = ''
        Context window in tokens.  From 64K on, the KV cache streams from RAM.  Past 262144 (the
        trained length) strata-prefetch turns yarn on by itself and derives the factor;
        `extraEngineArgs` can override it.
      '';
    };

    host = mkOption {
      type = types.str;
      default = "127.0.0.1";
      description = ''
        Listen address.  Use 0.0.0.0 to serve the LAN - with `apiKeyFile` set, or with
        `allowUnauthenticated` if you accept that anyone who can reach the port can use the model.
      '';
    };

    port = mkOption {
      type = types.port;
      default = 8080;
      description = "Port the API listens on.";
    };

    apiKeyFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = "File holding the API key (read through a systemd credential, never in the unit).";
    };

    allowUnauthenticated = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Serve without an API key.  Needed to use a non-loopback `host` with no key; the server then
        answers any request that can reach the port, so only do it on a network you control and
        keep `openFirewall` narrow.
      '';
    };

    allowedHosts = mkOption {
      type = types.listOf types.str;
      default = [ ];
      example = [ "ai.home.pleunetowne.com" ];
      description = ''
        Extra host names the server answers to, handed over as $STRATA_ALLOWED_HOSTS (Strata's
        `allowed_hosts`).  The server refuses a request whose Host header names a machine it does
        not know, to stop DNS rebinding, and the names it knows beyond loopback are only this PC's
        hostname, its LAN addresses and IP addresses.  So a client that reaches the endpoint by its
        domain - the llm host calling http://ai.home.pleunetowne.com:8080/v1 for Hermes - needs that
        name here, or it gets 403.
      '';
    };

    hfTokenFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = ''
        File holding a Hugging Face token, for gated model repos.  Strata's repos are public, so
        this is only needed when HF rate-limits the download.
      '';
    };

    openFirewall = mkOption {
      type = types.bool;
      default = false;
      description = "Open `port` in the firewall.  Only meaningful together with a non-loopback host.";
    };

    gpus = mkOption {
      type = types.listOf types.str;
      default = [ ];
      example = [ "0" ];
      description = ''
        CUDA device numbers (as nvidia-smi numbers them, PCI order).  Empty: the engine picks the
        card with the most VRAM.  Several: layer split across the cards.
      '';
    };

    vision = mkOption {
      type = types.enum [
        "off"
        "auto"
        "cpu"
        "gpu"
      ];
      default = "auto";
      description = ''
        Images (OpenAI image_url parts, Anthropic image blocks, the web chat's paperclip):
        `auto` picks the GPU encoder (about 1.4 GB of VRAM the engine reserves) on a card of 24 GB
        or more and the CPU encoder (a few seconds a picture, no VRAM) below, like upstream;
        `gpu` and `cpu` force one; `off` is text only.  With images on, strata-prefetch also fetches
        the picture reader file (about 0.9 GB) for the family.
      '';
    };

    parallel = mkOption {
      type = types.nullOr (types.ints.between 1 8);
      default = null;
      description = ''
        Several requests answered at once (2-8): each slot keeps its own session context in VRAM, so
        agents that run several sessions, or several people on one host, stop waiting for each other.
        Null (the default): requests take turns, one at a time.  The server turns this into the
        engine's batch slots and lowers the number itself when the card is short of VRAM; N over the
        engine's limit is clamped, not refused.
      '';
    };

    lowRam = mkOption {
      type = types.nullOr types.bool;
      default = null;
      description = ''
        Map the experts from the pack's experts.bin instead of copying them into RAM (needs a big GPU
        to stay fast).  Null: automatic from the model's RAM needs.
      '';
    };

    sampling = mkOption {
      type = types.attrsOf types.anything;
      default = { };
      example = literalExpression {
        temperature = 1.0;
        top_p = 0.95;
        top_k = 20;
      };
      description = "Sampling defaults for requests that leave the fields out.";
    };

    mcpServers = mkOption {
      type = types.attrsOf types.anything;
      default = { };
      description = ''
        MCP servers for the web app's chat, in Claude Desktop's format.  They run with this service's
        rights; only add ones you trust.
      '';
    };

    extraEngineArgs = mkOption {
      type = types.listOf types.str;
      default = [ ];
      example = [
        "--kv"
        "q4_0"
      ];
      description = "Extra arguments appended to the engine command line.";
    };

    kv = mkOption {
      type = types.nullOr (
        types.enum [
          "int8"
          "q4_0"
          "k8v4"
          "fp16"
        ]
      );
      default = null;
      example = "int8";
      description = ''
        KV-cache quantization (`--kv`), bought with accuracy.  `int8` halves the KV footprint and
        is what a long context on a modest card needs; null keeps the engine's own default.  Same
        as writing `extraEngineArgs = [ "--kv" "int8" ];`.
      '';
    };

    mockEngine = mkOption {
      type = types.bool;
      default = false;
      description = "Serve a scripted mock engine instead of the model (tests; no GPU or download).";
    };

    prefetchOnStart = mkOption {
      type = types.bool;
      default = true;
      description = "Download/prepare missing model files before starting (resumable, skipped when done).";
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.model != "IQ3_S" || cfg.family == "qwen";
        message = "nixflakes.services.strata: IQ3_S is only published for family = qwen.";
      }
      {
        assertion = cfg.model != "IQ1_M" || cfg.family == "coder";
        message = "nixflakes.services.strata: IQ1_M is only published for family = coder.";
      }
      {
        assertion = cfg.model != "IQ2_XS" || cfg.family != "coder";
        message = "nixflakes.services.strata: the coder family ships IQ1_M only; pick model = IQ1_M.";
      }
      {
        assertion =
          (builtins.elem cfg.model [
            "Gyro-S"
            "Gyro-M"
          ]) == (cfg.family == "gyro");
        message = ''
          nixflakes.services.strata: Gyro-S/Gyro-M belong to family = "gyro", and that family
          publishes nothing else.
        '';
      }
      {
        assertion =
          cfg.host == "127.0.0.1"
          || cfg.host == "localhost"
          || cfg.apiKeyFile != null
          || cfg.allowUnauthenticated;
        message = ''
          nixflakes.services.strata: exposing the API beyond loopback requires apiKeyFile, or
          allowUnauthenticated = true to serve it with no key at all.
        '';
      }
      {
        assertion = !cfg.allowUnauthenticated || cfg.apiKeyFile == null;
        message = ''
          nixflakes.services.strata: allowUnauthenticated and apiKeyFile contradict each other;
          drop one of them.
        '';
      }
      {
        assertion = !cfg.mockEngine || !cfg.prefetchOnStart;
        message = "nixflakes.services.strata: mockEngine requires prefetchOnStart = false.";
      }
      {
        assertion = !cfg.mockEngine || cfg.vision == "off";
        message = "nixflakes.services.strata: mockEngine serves text only; set vision = \"off\" with it.";
      }
      {
        assertion = cfg.mockEngine || cfg.vision == "off" || (cfg.package.passthru.vision or null) != null;
        message = "nixflakes.services.strata: with vision on, package must carry the vision encoder under passthru.vision.";
      }
      {
        assertion = cfg.mockEngine || (cfg.package.passthru.engine or null) != null;
        message = "nixflakes.services.strata: package must carry the engine under passthru.engine.";
      }
    ];

    systemd.services.strata = {
      description = "Strata: Qwen3.8-Flash-Next (125B MoE) local inference API";
      documentation = [ "https://github.com/Niko1221/Strata" ];
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
      path = [ cfg.package ];

      environment =
        { }
        // optionalAttrs (cfg.gpus != [ ]) {
          CUDA_DEVICE_ORDER = "PCI_BUS_ID";
          CUDA_VISIBLE_DEVICES = concatStringsSep "," cfg.gpus;
        }
        // optionalAttrs (cfg.allowedHosts != [ ]) {
          STRATA_ALLOWED_HOSTS = concatStringsSep "," cfg.allowedHosts;
        };

      # strata-prefetch downloads the quant, the picture reader and the tokenizer, builds the pack
      # and writes config.json for the server.  Dash-leading values must travel as --flag=VALUE
      # (argparse reads a dash-leading value after a space as its own option), which is why
      # extraEngineArgs is rendered as --extra-arg=<x>.
      preStart = mkIf (cfg.prefetchOnStart && !cfg.mockEngine) (
        toString (
          pkgs.writeShellScript "strata-prestart" (
            ''
              set -euo pipefail
              state="$STATE_DIRECTORY"
              exec ${cfg.package}/bin/strata-prefetch \
                --family ${escapeShellArg cfg.family} \
                --model ${escapeShellArg cfg.model} \
                --context ${toString cfg.context} \
                --data-dir "$state" \
            ''
            + optionalString (cfg.lowRam != null) ''
              --low-ram ${if cfg.lowRam then "on" else "off"} \
            ''
            + ''
              --vision ${cfg.vision} \
            ''
            + optionalString (cfg.vision != "off") ''
              --vision-exe ${escapeShellArg (toString cfg.package.passthru.vision)}/bin/strata-vision \
            ''
            + optionalString (cfg.parallel != null) ''
              --parallel ${toString cfg.parallel} \
            ''
            + optionalString (cfg.hfTokenFile != null) ''
              --hf-token-file "/run/credentials/strata.service/hf-token" \
            ''
            + ''
              --emit-config "$state/config.json" \
              --engine ${escapeShellArg (toString cfg.package.passthru.engine)}/bin/strata \
              --host ${escapeShellArg cfg.host} \
            ''
            + optionalString (cfg.apiKeyFile != null) ''
              --api-key-file "/run/credentials/strata.service/api-key" \
            ''
            + optionalString (cfg.gpus != [ ]) ''
              --gpu ${escapeShellArg (concatStringsSep "," cfg.gpus)} \
            ''
            + optionalString (cfg.sampling != { }) ''
              --sampling-json ${pkgs.writeText "strata-sampling.json" (builtins.toJSON cfg.sampling)} \
            ''
            + optionalString (cfg.mcpServers != { }) ''
              --mcp-json ${pkgs.writeText "strata-mcp.json" (builtins.toJSON cfg.mcpServers)} \
            ''
            + optionalString (cfg.kv != null) ''
              --extra-arg=--kv --extra-arg=${escapeShellArg cfg.kv} \
            ''
            + concatMapStrings (x: "--extra-arg=${escapeShellArg x} ") cfg.extraEngineArgs
          )
        )
      );

      serviceConfig = {
        Type = "simple";
        DynamicUser = true;
        StateDirectory = "strata";
        StateDirectoryMode = "0750";
        # First start: preStart downloads about 70 GB and builds the pack, and the default 90 s
        # TimeoutStartSec would kill it mid-download.  The download is resumable, but converge it in
        # one pass.  Applies to the start phase, including ExecStartPre.
        TimeoutStartSec = "0";
        WorkingDirectory = "%S/strata";
        UMask = "0077";
        Restart = "on-failure";
        RestartSec = 10;
        LoadCredential =
          (optional (cfg.apiKeyFile != null) "api-key:${cfg.apiKeyFile}")
          ++ (optional (cfg.hfTokenFile != null) "hf-token:${cfg.hfTokenFile}");
        ExecStart =
          if cfg.mockEngine then
            ''"${cfg.package}/bin/strata-serve --engine mock --port ${toString cfg.port} --host ${escapeShellArg cfg.host}"''
          else
            # The host, engine path and model settings come from the config.json prefetch wrote.
            "${cfg.package}/bin/strata-serve --engine strata --config %S/strata/config.json --port ${toString cfg.port}";
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictAddressFamilies = [
          "AF_UNIX"
          "AF_INET"
          "AF_INET6"
        ];
        LockPersonality = true;
        # The engine JITs and ggml loads device code at runtime; deny-write-execute breaks it.
        MemoryDenyWriteExecute = false;
      };
    };

    networking.firewall.allowedTCPPorts = mkIf cfg.openFirewall [ cfg.port ];
  };
}
