{
  modulesPath,
  pkgs,
  config,
  ...
}:
let
  # needs to match nas host
  nvidia_x11 = pkgs.linuxPackages.nvidia_x11_legacy535;

  # Prose for iocaine's poison generator. nam-shub-of-enki trains its Markov
  # chain on `sources.training-corpus`, and with no corpus it falls back to
  # iocaine's own embedded Rust and Lua source, which is why the first poisoned
  # pages came out as code fragments (`<title>Accept", options.table_name.
  # </title>`) instead of sentences. Public-domain books, plain text, pinned to
  # Wayback Machine snapshots because www.gutenberg.org answers 403 to some
  # egress addresses. Each snapshot keeps the Gutenberg header and the licence
  # footer, and both get cut below so they cannot leak into a poisoned page.
  gutenbergAlice = pkgs.fetchurl {
    name = "alice-in-wonderland.txt";
    url = "https://web.archive.org/web/20201124165115id_/https://www.gutenberg.org/files/11/11-0.txt";
    hash = "sha256-FRJNQMGCZ3wtkPuoAxAXPWNCjgWRzg3z6b3AGniaicY=";
  };
  gutenbergTwoCities = pkgs.fetchurl {
    name = "a-tale-of-two-cities.txt";
    url = "https://web.archive.org/web/20210129060353id_/https://www.gutenberg.org/files/98/98-0.txt";
    hash = "sha256-lxLz7E5TuGK8FR/VjY5ZuIiCKew17ARxgyscfdjUEWI=";
  };
  gutenbergOliverTwist = pkgs.fetchurl {
    name = "oliver-twist.txt";
    url = "https://web.archive.org/web/20210214031539id_/https://gutenberg.org/files/730/730-0.txt";
    hash = "sha256-gzqiSPa/e1AZYW6ybk67szbJJ3+j2BXV3jAMf9NIebM=";
  };
  gutenbergHuckFinn = pkgs.fetchurl {
    name = "huckleberry-finn.txt";
    url = "https://web.archive.org/web/20210213202511id_/https://gutenberg.org/files/76/76-0.txt";
    hash = "sha256-vWXk9KOgxh0V2uPAb230wE+Qx15YoJbGDVld0XffUK8=";
  };
  gutenbergTimeMachine = pkgs.fetchurl {
    name = "the-time-machine.txt";
    url = "https://web.archive.org/web/20210423195915id_/http://www.gutenberg.org/files/35/35-0.txt";
    hash = "sha256-Ux4R0RhcpKhst6z2D9RZQ8FZGUWupA9PHB6ld9/W4tk=";
  };

  # Everything between the two `*** ... PROJECT GUTENBERG ... ***` banners, with
  # the byte-order mark and CRLF line endings dropped so the Markov chain only
  # ever sees the book itself.
  poisonCorpus = pkgs.runCommand "iocaine-poison-corpus" { } ''
    mkdir -p "$out"
    strip() {
      awk '
        /\*\*\* START OF (THE |THIS )?PROJECT GUTENBERG/ { f = 1; next }
        /\*\*\* END OF (THE |THIS )?PROJECT GUTENBERG/ { f = 0 }
        # Some books close with a plain `End of Project Gutenberg ...` line
        # instead of a banner, so it survives the banners above.
        f && $0 !~ /^End of .*Project Gutenberg/
      ' "$1" | sed -e '1s/^\xef\xbb\xbf//' -e 's/\r$//' > "$2"
    }
    strip ${gutenbergAlice} "$out/alice-in-wonderland.txt"
    strip ${gutenbergTwoCities} "$out/a-tale-of-two-cities.txt"
    strip ${gutenbergOliverTwist} "$out/oliver-twist.txt"
    strip ${gutenbergHuckFinn} "$out/huckleberry-finn.txt"
    strip ${gutenbergTimeMachine} "$out/the-time-machine.txt"
  '';

  # Where `environment.etc` below lands the corpus, as absolute paths: the
  # handler's working directory is its state directory, so relative paths would
  # not resolve.
  corpusPaths = map (name: "/etc/iocaine/corpus/${name}") [
    "alice-in-wonderland.txt"
    "a-tale-of-two-cities.txt"
    "oliver-twist.txt"
    "huckleberry-finn.txt"
    "the-time-machine.txt"
  ];
in
{
  imports = [
    "${modulesPath}/virtualisation/lxc-container.nix"
  ];

  nixpkgs.hostPlatform = {
    # gcc.arch = "alderlake";
    # gcc.tune = "alderlake";
    system = "x86_64-linux";
  };

  environment.systemPackages = with pkgs; [
    vim
    iocaine
    #nvidia_x11.bin
  ];

  # Anti-scraper layer for everything HAProxy fronts. HAProxy runs on OPNsense,
  # not in this container, so both request-serving servers listen on TCP: the
  # gateway asks the SPOP agent for a decision and forwards the requests it
  # blocks to the HTTP output server. Both binds are wildcard sockets, so a
  # single listener serves IPv4 and IPv6 (Linux leaves bindv6only at 0). The
  # Markov corpus the poison pages are written from is `poisonCorpus` below.
  # The OPNsense side lives in docs/iocaine-haproxy.md.
  services.iocaine = {
    enable = true;
    settings = {
      # Produces the poisoned responses. HAProxy only sends requests the SPOA
      # already decided to block, so this port is a decoy rather than a real
      # origin. Reachable from the gateway, not from the loopback alone.
      server.http = {
        bind = "[::]:42069";
        mode = "http";
        use.handler-from = "nam-shub-of-enki";
        use.metrics = "metrics";
      };
      # The SPOP agent HAProxy asks for a decision. SPOP speaks over TCP here,
      # which is what a gateway-hosted HAProxy needs; `unix-socket-access` only
      # applies to unix binds, so it is gone along with the socket path.
      server.spoa = {
        bind = "[::]:42070";
        mode = "haproxy-spoa";
        use.handler-from = "nam-shub-of-enki";
        use.metrics = "metrics";
      };
      # Prometheus on the NAS scrapes this over the container bridge, so it is
      # published rather than loopback-only. See platforms/nas.nix.
      server.metrics = {
        bind = "[::]:42042";
        mode = "prometheus";
        persist-path = "/var/lib/iocaine/metrics.json";
        persist-interval = "10m";
      };
      handler.nam-shub-of-enki = {
        path = pkgs.nam-shub-of-enki;
        language = "roto";
        # Every check whose data file is missing is disabled, so this runs
        # without wordlists, an ASN database, or an ai-robots-txt file.
        # Point sources.* and checks.* at files under /etc/iocaine or
        # /var/lib/iocaine to turn them on; extraSettingsPaths merges config
        # that must not land in the store.
        config = {
          inherits = "default";
          # Real prose, so a poisoned page reads like a page. `ProtectSystem`
          # makes the unit's filesystem read-only but `/etc` stays readable,
          # and `environment.etc` below puts these files at exactly this path.
          sources.training-corpus = corpusPaths;
          # The same books feed the slug generator: `sources.wordlists` backs
          # WORDLIST, which writes the fake link paths and the JavaScript
          # identifiers. Left on its default it produces code-ish slugs such as
          # `Opts-nval`, which is the same defect as the Markov text.
          sources.wordlists = corpusPaths;
          # Honeypot links planted in the Forgejo footer by platforms/git.nix.
          # `+` keeps the auto-generated poison id nam-shub-of-enki persists in
          # its state file; the token is the bait path, matched as a substring
          # of the path or of the Referer, and it answers `garbage` for both
          # the SPOA decision and the poisoned response.
          checks.generated-urls.identifiers = [
            "+"
            "guestbook-7c4b59dd"
          ];
        };
      };
      firewall.enable = false;
    };
  };

  # The handler is store code and the upstream restartTriggers only cover the
  # generated config, so a new deployment has to restart the unit. The corpus is
  # listed too because the config only names the `/etc` paths, which never
  # change even when the corpus behind them does.
  systemd.services.iocaine.restartTriggers = [
    pkgs.nam-shub-of-enki
    poisonCorpus
  ];

  # /etc/iocaine/corpus, next to the generated /etc/iocaine/iocaine.json.
  environment.etc."iocaine/corpus".source = poisonCorpus;

  # iocaine's SPOP agent and output server, for HAProxy on the gateway, plus its
  # metrics server for the NAS. `allowedTCPPorts` is installed with ip46tables,
  # so this covers both families.
  networking.firewall.allowedTCPPorts = [
    config.services.forgejo.settings.server.HTTP_PORT
    12345
    42042
    42069
    42070
    8080
    8888
  ];

  # Ship the container's journal to the Loki on the NAS. The upstream Alloy
  # module already puts the service in the systemd-journal group, which is what
  # reading the journal needs.
  services.alloy.enable = true;

  # Journald logs from this container. Alloy reads journald fields as internal
  # __journal_* labels and drops them before forwarding, so relabel them into
  # real Loki labels; otherwise every query is a bare text search.
  environment.etc."alloy/config.alloy".text = ''
    loki.relabel "journal" {
      forward_to = []

      rule {
        source_labels = ["__journal__systemd_unit"]
        target_label = "unit"
      }

      rule {
        source_labels = ["__journal_priority_keyword"]
        target_label = "priority"
      }
    }

    loki.source.journal "journal" {
      forward_to = [loki.write.loki.receiver]
      relabel_rules = loki.relabel.journal.rules
      labels = {
        host = "jump",
      }
    }

    loki.write "loki" {
      endpoint {
        url = "http://nas.home.pleunetowne.com:3030/loki/api/v1/push"
      }
    }
  '';

  networking = {
    dhcpcd.enable = false;
    useDHCP = false;
    useHostResolvConf = false;
  };

  systemd.network = {
    enable = true;
    networks."50-eth0" = {
      matchConfig.Name = "eth0";
      networkConfig = {
        DHCP = "yes";
        IPv6AcceptRA = true;
      };
      linkConfig.RequiredForOnline = "routable";
    };
  };

  hardware.graphics = {
    enable = true;
    extraPackages = with pkgs; [
      intel-media-driver
      libvdpau-va-gl
      nvidia-vaapi-driver
      nvidia_x11.out
      vpl-gpu-rt
    ];
  };

  services.openssh = {
    enable = true;
    # TODO: deploy as non-root
    # DenyUsers = "root";

  };

  nixflakes.makeUser = true;
  nixuserflakes = {
    theme.name = "none";
    gui = false;
  };
  system.stateVersion = "24.11";
}
