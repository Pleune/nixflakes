{
  pkgs,
  NixOS-WSL,
  username,
  ...
}:
{
  imports = [ NixOS-WSL.nixosModules.wsl ];
  wsl = {
    enable = true;
    defaultUser = "${username}";
    nativeSystemd = true;
    useWindowsDriver = true;
    startMenuLaunchers = true;
  };

  services.udev.enable = true;
  virtualisation.podman.enable = true;

  time.timeZone = "America/Detroit";
  i18n.defaultLocale = "en_US.UTF-8";
  networking.timeServers = [ "time.windows.com" ];

  hardware.graphics = {
    enable = true;

    extraPackages = with pkgs; [
      mesa.drivers
      libvdpau-va-gl
    ];
  };

  users.users.${username}.extraGroups = [ "video" ];

  home-manager.users.${username} = {
    # just make vscode with the WSL remote extension work
    home.file.".vscode-server/server-env-setup".text = "PATH=$PATH:/run/current-system/sw/bin/";

    nixflakes = {
      theme = "wsl";
      gui = false;
      daily = false;
    };
  };

  system.stateVersion = "23.11";
}
