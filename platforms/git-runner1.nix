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

  virtualisation.podman = {
    enable = true;
    dockerSocket.enable = true;
    autoPrune.enable = true;
  };

  nixflakes.agenix.enable = true;
  age.secrets."forgejo_runner.token" = {
    file = "${private.secrets}/git-runner1.token";
    mode = "444"; # setting owner to "gitea-runner" gives invalid user "gitea-runner:0" ???
  };
  services.gitea-actions-runner = {
    # the registration binary has a new name?
    # package = pkgs.forgejo-runner;
    instances."local-forgejo" = {
      enable = true;
      name = "local-runner1";
      url = "https://git.pleunetowne.com/";
      tokenFile = config.age.secrets."forgejo_runner.token".path;
      labels = [
        "ubuntu-22.04:docker://ghcr.io/catthehacker/ubuntu:act-22.04"
        "debian-latest:docker://node:18-bullseye"
        "ubuntu-latest:docker://node:18-bullseye"
        "docker:docker://code.forgejo.org/oci/alpine:3.18"
      ];
    };
  };

  nixflakes.makeUser = false;
  system.stateVersion = "25.05"; # Did you read the comment?
}
