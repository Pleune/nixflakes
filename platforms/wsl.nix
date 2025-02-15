{
  pkgs,
  NixOS-WSL,
  username,
  ...
}:
{
  imports = [ NixOS-WSL.nixosModules.wsl ];

  nixpkgs.hostPlatform = {
    # gcc.arch = "x86-64-v3";
    # gcc.tune = "alderlake";
    system = "x86_64-linux";
  };

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

  nix = {
    settings = {
      auto-optimise-store = true;

      # Just allow nix to build with all gcc.arch. We don't know what system wsl will be used on
      system-features = [
        "gccarch-alderlake"
        "gccarch-broadwell"
        "gccarch-haswell"
        "gccarch-ivybridge"
        "gccarch-sandybridge"
        "gccarch-silvermont"
        "gccarch-skylake"
        "gccarch-x86-64-v2"
        "gccarch-x86-64-v3"
        "gccarch-x86-64-v3"
        "big-parallel"
        "kvm"
      ];
    };
  };

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
