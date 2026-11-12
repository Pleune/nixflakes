{
  lib,
  pkgs,
  runCommand,
  strataModule,
}:

# The module's device pin and engine passthroughs, evaluated without a NixOS host:
# CUDA_VISIBLE_DEVICES from `gpus`, and --parallel, --low-ram, --sampling-json, --mcp-json and
# --gpu reaching strata-prefetch, plus the quant/host assertions.  The package is a stub here -
# evalModules does not need a built one.
let
  fullPkg = {
    outPath = "/nix/store/00000000000000000000000000000000-strata";
    passthru.engine = "/nix/store/11111111111111111111111111111111-strata-engine";
    passthru.vision = "/nix/store/22222222222222222222222222222222-strata-vision";
  };

  # The module is a NixOS module; this stub carries the pieces of NixOS it names that a bare
  # evalModules does not (networking.firewall.allowedTCPPorts, the top-level assertions list, the
  # systemd unit).  The unit is read back as written (types.raw).
  shim = {
    options.networking.firewall.allowedTCPPorts = lib.mkOption {
      type = lib.types.listOf lib.types.port;
      default = [ ];
    };
    options.assertions = lib.mkOption {
      type = lib.types.listOf lib.types.unspecified;
      default = [ ];
    };
    options.systemd.services = lib.mkOption {
      type = lib.types.lazyAttrsOf lib.types.raw;
    };
  };

  eval =
    cfg:
    (lib.evalModules {
      modules = [
        { _module.args.pkgs = pkgs; }
        shim
        strataModule
        {
          nixflakes.services.strata = cfg // {
            package = fullPkg;
          };
        }
      ];
    }).config;

  pinned = eval {
    enable = true;
    vision = "off";
    gpus = [ "1" ];
    parallel = 2;
    lowRam = true;
    sampling = {
      temperature = 0.7;
      top_k = 40;
    };
    mcpServers = {
      demo.command = "/bin/true";
    };
  };
  coderMismatch = eval {
    enable = true;
    vision = "off";
    family = "coder";
    model = "IQ2_XS";
  };
  coderGood = eval {
    enable = true;
    vision = "off";
    family = "coder";
    model = "IQ1_M";
  };
  qwenIQ3S = eval {
    enable = true;
    vision = "off";
    family = "qwen";
    model = "IQ3_S";
  };
  openHost = eval {
    enable = true;
    vision = "off";
    host = "0.0.0.0";
  };
  openHostWithKey = eval {
    enable = true;
    vision = "off";
    host = "0.0.0.0";
    apiKeyFile = "/run/secrets/strata-api.key";
  };
  mockWithPrefetch = eval {
    enable = true;
    mockEngine = true;
    prefetchOnStart = true;
    vision = "off";
  };

  # The module's assertions are { assertion, message } records; a refused config contributes one
  # whose assertion is false.
  refused = cfg: builtins.any (a: !a.assertion) cfg.assertions;

  # types.raw keeps mkIf wrappers ({ _type = "if"; ... }) inside the value; unwrap the one level
  # this check reads (preStart is mkIf'd on prefetchOnStart).
  unIf = v: if (v ? _type && v._type == "if") then (if v.condition then v.content else "") else v;

  psPinned = unIf pinned.systemd.services.strata.preStart;

  # The device pin travels as unit environment, not inside the preStart script; the check's shim
  # keeps `environment` exactly as the module wrote it (types.raw), so read the values directly.
  envPinned = pinned.systemd.services.strata.environment or { };
in
# Checked at eval time, so a wrong assertion set fails with the module's own message rather than
# silently passing a grep.
assert refused coderMismatch;
assert !refused coderGood;
assert !refused qwenIQ3S;
assert refused openHost;
assert !refused openHostWithKey;
assert refused mockWithPrefetch;
assert envPinned.CUDA_DEVICE_ORDER or null == "PCI_BUS_ID";
assert envPinned.CUDA_VISIBLE_DEVICES or null == "1";
runCommand "strata-module-parallel" { } ''
  # Paths in the generated script are shell-quoted, so these patterns carry the quotes.
  grep -q -- "--gpu 1" ${psPinned}
  grep -q -- "--parallel 2" ${psPinned}
  grep -q -- "--low-ram on" ${psPinned}
  grep -q -- "--sampling-json " ${psPinned}
  grep -q -- "--mcp-json " ${psPinned}

  # The sampling and MCP files are written into the store by the module and carry the values.
  grep -q 'temperature' $(grep -o -- "--sampling-json [^ ]*" ${psPinned} | cut -d' ' -f2)
  grep -q 'demo' $(grep -o -- "--mcp-json [^ ]*" ${psPinned} | cut -d' ' -f2)

  touch $out
''
