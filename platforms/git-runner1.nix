{
  modulesPath,
  pkgs,
  private,
  config,
  ...
}:

{
  imports = [
    "${modulesPath}/virtualisation/lxc-container.nix"
  ];

  environment.systemPackages = with pkgs; [ vim ];

  networking = {
    dhcpcd.enable = false;
    useDHCP = false;
    useHostResolvConf = false;

    # not supposed to be needed.. but it is?
    firewall.interfaces."podman+".allowedUDPPorts = [
      53
      5353
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

  nix = {
    settings = {
      # minimize memory usage
      max-jobs = 2;
      max-substitution-jobs = 1;

      # minimize store duplication immedeately
      auto-optimise-store = true;
    };

    gc = {
      automatic = true;
      dates = "daily";
      options = "--delete-older-than 120d";
    };

    optimise.automatic = true;
  };

  virtualisation.podman = {
    enable = true;
    dockerSocket.enable = true;
    autoPrune.enable = true;
    defaultNetwork.settings = {
      dns_enabled = true;
    };
  };

  nixflakes.agenix.enable = true;
  age.secrets = {
    "forgejo_runner.token" = {
      file = "${private.secrets}/git-runner1.token";
      owner = "gitea-runner";
      mode = "660";
    };
    "nix-serve.key" = {
      file = "${private.secrets}/git-runner1-nix-serve.key";
      # owner = "nix-serve";
      mode = "660";
    };
  };

  services.gitea-actions-runner = {
    # the registration binary has a new name?
    # package = pkgs.forgejo-runner;
    instances."default" = {
      enable = true;
      name = "runner1-default";
      url = "https://git.pleunetowne.com/";
      tokenFile = config.age.secrets."forgejo_runner.token".path;
      labels = [
        "ubuntu-22.04:docker://ghcr.io/catthehacker/ubuntu:act-22.04"
        "debian-latest:docker://node:18-bullseye"
        "ubuntu-latest:docker://node:18-bullseye"
      ];
      settings.container = {
        force_rebuild = true;
        force_pull = true;
      };
    };

    # This runner, for 'run-as: nix', allows using nixos from the host
    instances."nix" = {
      enable = true;
      name = "runner1-nix";
      url = "https://git.pleunetowne.com/";
      tokenFile = config.age.secrets."forgejo_runner.token".path;
      labels = [
        "nix:docker://alpine:latest"
      ];
      settings.runner.envs = {
        NIX_REMOTE = "daemon";
        PATH = "/nix/var/nix/profiles/system/sw/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${pkgs.nodejs}/bin:${pkgs.podman}/bin";
        NIX_PATH = "nixpkgs=/nix/var/nix/profiles/per-user/root/channels/nixos/nixpkgs";
        NIX_SSL_CERT_FILE = "/nix/var/nix/profiles/system/etc/ssl/certs/ca-bundle.crt";
      };
      settings.container = {
        options = "--mount type=bind,src=/nix,dst=/nix,ro --mount type=bind,src=/etc/containers,dst=/etc/containers,ro --mount type=bind,src=/etc/nix,dst=/etc/nix,ro --mount type=bind,src=/etc/static,dst=/etc/static,ro";
        valid_volumes = [
          "/nix"
          "/etc/containers"
          "/etc/nix"
          "/etc/static"
        ];
      };
    };
  };

  services.nix-serve = {
    enable = true;
    package = pkgs.nix-serve-ng;
    openFirewall = true;
    secretKeyFile = config.age.secrets."nix-serve.key".path;
  };

  nixflakes.makeUser = false;
  system.stateVersion = "25.05";
}
