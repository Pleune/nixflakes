{
  modulesPath,
  pkgs,
  config,
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

  # Anti-scraper layer for everything HAProxy fronts. HAProxy asks the SPOA
  # agent at /run/iocaine/iocaine.sock for a decision and serves generated
  # garbage from 127.0.0.1:42069, so HAProxy has to run in this container.
  # The haproxy.cfg side lives in docs/iocaine-haproxy.md.
  services.iocaine = {
    enable = true;
    settings = {
      # Produces the poisoned responses.
      server.http = {
        bind = "127.0.0.1:42069";
        mode = "http";
        use.handler-from = "nam-shub-of-enki";
        use.metrics = "metrics";
      };
      # The SPOP agent HAProxy asks for a decision. Group access so a HAProxy
      # running as the iocaine group can reach it; root reaches it regardless.
      server.spoa = {
        bind = "/run/iocaine/iocaine.sock";
        unix-socket-access = "group";
        mode = "haproxy-spoa";
        use.handler-from = "nam-shub-of-enki";
        use.metrics = "metrics";
      };
      server.metrics = {
        bind = "127.0.0.1:42042";
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
        };
      };
      firewall.enable = false;
    };
  };

  # The handler is store code and the upstream restartTriggers only cover the
  # generated config, so a new deployment has to restart the unit.
  systemd.services.iocaine.restartTriggers = [ pkgs.nam-shub-of-enki ];

  networking.firewall.allowedTCPPorts = [
    config.services.forgejo.settings.server.HTTP_PORT
    12345
    8080
    8888
  ];

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
