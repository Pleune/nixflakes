{
  lib,
  pkgs,
  runCommand,
  strataModule,
}:

# Strata answers only to host names it knows (server.py's DNS-rebinding guard): a request whose
# Host header names another machine gets 403.  Beyond loopback that set is this PC's hostname, its
# LAN addresses and IP addresses, plus `allowedHosts`, which the module hands to the server through
# $STRATA_ALLOWED_HOSTS.  Without it a client that calls the endpoint by its domain - the llm host
# reaching http://ai.home.pleunetowne.com:8080/v1 for Hermes - is refused, so the option has to
# reach the unit's environment.
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

  named = eval {
    enable = true;
    vision = "off";
    host = "0.0.0.0";
    allowUnauthenticated = true;
    allowedHosts = [
      "ai.home.pleunetowne.com"
      "strata.internal"
    ];
  };

  plain = eval {
    enable = true;
    vision = "off";
  };

  envOf = svc: svc.environment or { };

  # Comma-separated, the form server.py's allowed_hosts_of parses out of the environment.
  namedEnv = envOf named.systemd.services.strata;
  namedVal = namedEnv.STRATA_ALLOWED_HOSTS or "";

  # Nothing configured: no variable at all, so the server keeps its own default set.
  plainVal = (envOf plain.systemd.services.strata).STRATA_ALLOWED_HOSTS or "";
in
runCommand "strata-module-hosts" { } ''
  test '${namedVal}' = 'ai.home.pleunetowne.com,strata.internal' || {
    echo "allowedHosts must reach the unit environment as a comma-separated STRATA_ALLOWED_HOSTS";
    exit 1;
  }

  test -z '${plainVal}' || {
    echo "an empty allowedHosts must not set STRATA_ALLOWED_HOSTS"; exit 1;
  }

  touch $out
''
