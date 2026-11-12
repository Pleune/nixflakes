{
  lib,
  pkgs,
  runCommand,
  strataModule,
}:

# The module's vision plumbing, evaluated without a NixOS host: which encoder path reaches
# strata-prefetch, the device pin, the credential paths, and the assertion that a package without
# an encoder cannot run with images on.  The package is a stub here - evalModules does not need a
# built one.
let
  fullPkg = {
    outPath = "/nix/store/00000000000000000000000000000000-strata";
    passthru.engine = "/nix/store/11111111111111111111111111111111-strata-engine";
    passthru.vision = "/nix/store/22222222222222222222222222222222-strata-vision";
  };

  # A bundle that carries the engine but no encoder (e.g. built with vision = null).
  engineOnlyPkg = {
    outPath = "/nix/store/333333333333333333333333333333333-strata";
    passthru.engine = "/nix/store/11111111111111111111111111111111-strata-engine";
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
    cfg: pkg:
    (lib.evalModules {
      modules = [
        { _module.args.pkgs = pkgs; }
        shim
        strataModule
        {
          nixflakes.services.strata = cfg // {
            package = pkg;
          };
        }
      ];
    }).config;

  gpu = eval {
    enable = true;
    vision = "gpu";
    gpus = [ "0" ];
    apiKeyFile = "/run/secrets/strata-api.key";
  } fullPkg;
  cpu = eval {
    enable = true;
    vision = "cpu";
  } fullPkg;
  off = eval {
    enable = true;
    vision = "off";
  } fullPkg;
  noEncoder = eval {
    enable = true;
    vision = "gpu";
  } engineOnlyPkg;

  # types.raw keeps mkIf wrappers ({ _type = "if"; ... }) inside the value; unwrap the one level
  # this check reads (preStart is mkIf'd on prefetchOnStart).  What comes out is the store path of
  # the writeShellScript derivation; interpolating it below builds it so grep can read it.
  unIf = v: if (v ? _type && v._type == "if") then (if v.condition then v.content else "") else v;

  # The module's assertions are { assertion, message } records; a refused config contributes one
  # whose assertion is false.
  refused = cfg: builtins.any (a: !a.assertion) cfg.assertions;

  psGpu = unIf gpu.systemd.services.strata.preStart;
  psCpu = unIf cpu.systemd.services.strata.preStart;
  psOff = unIf off.systemd.services.strata.preStart;

  # The device pin travels as unit environment, not inside the preStart script; the check's shim
  # keeps `environment` exactly as the module wrote it (types.raw), so read the values directly.
  envOf = svc: svc.environment or { };
  envGpu = envOf gpu.systemd.services.strata;
  envOff = envOf off.systemd.services.strata;
in
# Evaluated here rather than grepped, so a wrong assertion set fails with the module's own message.
assert refused noEncoder;
assert !refused gpu;
assert !refused off;
assert envGpu.CUDA_DEVICE_ORDER or null == "PCI_BUS_ID";
assert envGpu.CUDA_VISIBLE_DEVICES or null == "0";
# No gpus listed => no device pin at all, so the engine sees every card on the box.
assert envOff == { };
runCommand "strata-module-vision" { } ''
  # gpu: the encoder path is passed through and the API key is loaded as a credential.  Paths in
  # the generated script are shell-quoted, so these patterns carry the quotes.
  grep -q -- "--vision gpu" ${psGpu}
  grep -q -- "--vision-exe /nix/store/22222222222222222222222222222222-strata-vision/bin/strata-vision" ${psGpu}
  grep -q -- '--api-key-file "/run/credentials/strata.service/api-key"' ${psGpu}

  # cpu: the same encoder path with --vision cpu (the CPU build shares $out/bin/strata-vision)
  grep -q -- "--vision cpu" ${psCpu}
  grep -q -- "--vision-exe /nix/store/22222222222222222222222222222222-strata-vision/bin/strata-vision" ${psCpu}

  # off: the reader is still named (prefetch takes --vision off explicitly) but no encoder is
  # passed, and no credential file is loaded.
  grep -q -- "--vision off" ${psOff}
  if grep -q -- "--vision-exe" ${psOff}; then
    echo "vision off must not pass an encoder path"; exit 1
  fi
  if grep -q "api-key" ${psOff}; then
    echo "vision off must not reference the api key"; exit 1
  fi

  touch $out
''
