{
  lib,
  pkgs,
  runCommand,
  strataModule,
}:

# The gyro family as the module serves it: the size names, --kv reaching the engine through
# strata-prefetch's --extra-arg, serving the LAN with no key, and the pairings the assertions
# refuse.  Evaluated without a NixOS host, against a stub package (see ./module-vision.nix for why
# the shim exists); patterns are matched with an optional quote because the module shell-quotes
# the values it passes to strata-prefetch.
let
  fullPkg = {
    outPath = "/nix/store/000000000000000000000000000000000-strata";
    passthru.engine = "/nix/store/11111111111111111111111111111111-strata-engine";
    passthru.vision = "/nix/store/22222222222222222222222222222222-strata-vision";
  };

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

  # What ai.nix runs: gyro on one card, 131072 tokens, int8 KV, the CPU encoder, the LAN with no key.
  served = eval {
    enable = true;
    family = "gyro";
    model = "Gyro-M";
    context = 131072;
    kv = "int8";
    vision = "cpu";
    gpus = [ "0" ];
    host = "0.0.0.0";
    port = 8080;
    allowUnauthenticated = true;
    openFirewall = true;
  };
  loopback = eval {
    enable = true;
    family = "gyro";
    model = "Gyro-S";
    vision = "off";
  };
  noKeyOnLan = eval {
    enable = true;
    vision = "off";
    host = "0.0.0.0";
  };
  keyAndUnauthenticated = eval {
    enable = true;
    vision = "off";
    host = "0.0.0.0";
    allowUnauthenticated = true;
    apiKeyFile = "/run/secrets/strata-api.key";
  };
  wrongFamily = eval {
    enable = true;
    family = "swift";
    model = "Gyro-M";
    vision = "off";
  };
  wrongModel = eval {
    enable = true;
    family = "gyro";
    model = "IQ2_XS";
    vision = "off";
  };

  unIf = v: if (v ? _type && v._type == "if") then (if v.condition then v.content else "") else v;
  refused = cfg: builtins.any (a: !a.assertion) cfg.assertions;
  envOf = svc: svc.environment or { };

  psServed = unIf served.systemd.services.strata.preStart;
  psLoopback = unIf loopback.systemd.services.strata.preStart;
  gpuPin = envOf served.systemd.services.strata;
  gpuPinLoopback = envOf loopback.systemd.services.strata;
in
# Evaluated here rather than grepped, so a wrong assertion set fails with the module's own message.
assert !refused served;
assert !refused loopback;
assert refused noKeyOnLan;
assert refused keyAndUnauthenticated;
assert refused wrongFamily;
assert refused wrongModel;
assert served.networking.firewall.allowedTCPPorts == [ 8080 ];
assert loopback.networking.firewall.allowedTCPPorts == [ ];
assert gpuPin.CUDA_VISIBLE_DEVICES or null == "0";
assert gpuPin.CUDA_DEVICE_ORDER or null == "PCI_BUS_ID";
assert gpuPinLoopback.CUDA_VISIBLE_DEVICES or null == null;
runCommand "strata-module-gyro" { } ''
  grep -Eq -- '--family "?gyro' ${psServed}
  grep -Eq -- '--model "?Gyro-M' ${psServed}
  grep -Eq -- '--context 131072' ${psServed}
  grep -Eq -- '--vision cpu' ${psServed}

  # --kv reaches the engine as a pair of --extra-arg values, in the =VALUE form argparse needs.
  grep -Eq -- '--extra-arg="?--kv' ${psServed}
  grep -Eq -- '--extra-arg="?int8' ${psServed}
  if grep -q -- '--extra-arg --kv' ${psServed}; then
    echo "--extra-arg must use the =VALUE form for dash-leading arguments"; exit 1
  fi

  # Serving with no key loads no credential, and the server is told to listen on 0.0.0.0.
  grep -Eq -- '--host "?0\.0\.0\.0' ${psServed}
  if grep -q "api-key" ${psServed}; then
    echo "allowUnauthenticated must not reference an api key"; exit 1
  fi

  # Loopback by default keeps no device pin and no key either, and gyro needs no --compat-bf16
  # from here - strata-prefetch adds it to the pack build itself.
  if grep -q "api-key" ${psLoopback}; then
    echo "a loopback config with no apiKeyFile must not reference a key"; exit 1
  fi

  touch $out
''
