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

  environment.systemPackages = with pkgs; [ vim ];
  networking.firewall.allowedTCPPorts = [ config.services.forgejo.settings.server.HTTP_PORT ];

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

  nixflakes.makeUser = true;
  nixuserflakes = {
    theme = "none";
    gui = false;
    daily = false;
  };
  system.stateVersion = "24.11";
}
