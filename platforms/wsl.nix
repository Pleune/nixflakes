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

  time.timeZone = "America/Detroit";
  i18n.defaultLocale = "en_US.UTF-8";
  networking.timeServers = [ "time.windows.com" ];

  hardware.graphics = {
    enable = true;

    extraPackages = with pkgs; [
      mesa.drivers
      libvdpau-va-gl
      #(libedit.overrideAttrs (attrs: {
      #  postInstall = (attrs.postInstall or "") + ''ln -s $out/lib/libedit.so $out/lib/libedit.so.2'';
      #}))
      #linuxPackages.nvidia_x11
    ];
  };

  systemd.services."user-runtime-dir@" = {
    overrideStrategy = "asDropin";
    unitConfig.ConditionPathExists = "!/run/user/%i";
  };

  environment.sessionVariables = {
    #CUDA_PATH = "${pkgs.cudatoolkit}";
    #EXTRA_LDFLAGS = "-L/lib -L${pkgs.linuxPackages.nvidia_x11}/lib";
    EXTRA_CCFLAGS = "-I/usr/include";
    LD_LIBRARY_PATH = [
      "/usr/lib/wsl/lib"
      #"${pkgs.linuxPackages.nvidia_x11}/lib"
      #"${pkgs.ncurses5}/lib"
      "/run/opengl-driver/lib"
    ];
    #MESA_D3D12_DEFAULT_ADAPTER_NAME = "Nvidia";
  };

  users.users.${username}.extraGroups = [ "video" ];
  environment.systemPackages = with pkgs; [
    glxinfo
    libva-utils
    cudatoolkit
  ];

  home-manager.users.${username} = {
    # just make vscode with the WSL remote extension work
    home.file.".vscode-server/server-env-setup".text = "PATH=$PATH:/run/current-system/sw/bin/";

    nixflakes = {
      theme = "wsl";
      gui = false;
      daily = false;
    };
  };
}
