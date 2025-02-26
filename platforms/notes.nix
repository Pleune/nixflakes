{
  pkgs,
  config,
  modulesPath,
  private,
  ...
}:

let
  hostname = "notes.pleunetowne.com";
in
{
  imports = [
    "${modulesPath}/virtualisation/lxc-container.nix"
  ];

  nixpkgs.hostPlatform = {
    gcc.arch = "alderlake";
    gcc.tune = "alderlake";
    system = "x86_64-linux";
  };

  environment.systemPackages = with pkgs; [ vim ];
  nixpkgs.config.allowUnfree = true;

  networking = {
    dhcpcd.enable = false;
    useDHCP = false;
    useHostResolvConf = false;
    firewall.allowedTCPPorts = [ 443 ];
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

  nixflakes.agenix.enable = true;
  age.secrets."ssl.key" = {
    file = "${private.secrets}/PT-Notes.key";
    owner = config.systemd.services.nginx.serviceConfig.User;
  };
  age.secrets."ssl.crt" = {
    file = "${private.secrets}/PT-Notes.crt";
    owner = config.systemd.services.nginx.serviceConfig.User;
  };

  services = {
    trilium-server = {
      enable = true;
      package = pkgs.trilium-next-server;
      nginx = {
        enable = true;
        hostName = hostname;
      };
    };
    nginx = {
      virtualHosts.${hostname} = {
        forceSSL = true;
        sslCertificate = config.age.secrets."ssl.crt".path;
        sslCertificateKey = config.age.secrets."ssl.key".path;
      };
    };
  };

  nixflakes.makeUser = false;
  system.stateVersion = "24.11"; # Did you read the comment?
}
