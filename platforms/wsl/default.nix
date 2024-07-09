{
  pkgs,
  username,
  NixOS-WSL,
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

  hardware.opengl = {
    enable = true;
    driSupport = true;
    setLdLibraryPath = true;

    extraPackages = with pkgs; [
      mesa.drivers
      libvdpau-va-gl
      (libedit.overrideAttrs (attrs: {postInstall = (attrs.postInstall or "") + ''ln -s $out/lib/libedit.so $out/lib/libedit.so.2'';}))
      linuxPackages.nvidia_x11
    ];
  };

  systemd.services."user-runtime-dir@" = {
    overrideStrategy = "asDropin";
    unitConfig.ConditionPathExists = "!/run/user/%i";
  };

  programs.bash.shellInit = ''
      export CUDA_PATH=${pkgs.cudatoolkit}
      export LD_LIBRARY_PATH=$LD_LIBRARY_PATH:/usr/lib/wsl/lib:${pkgs.linuxPackages.nvidia_x11}/lib:${pkgs.ncurses5}/lib
      export EXTRA_LDFLAGS="-L/lib -L${pkgs.linuxPackages.nvidia_x11}/lib"
      export EXTRA_CCFLAGS="-I/usr/include"
   '';

  users.users.${username}.extraGroups = [ "video" ];
  environment.systemPackages = with pkgs; [ glxinfo libva-utils cudatoolkit ];
  # just make vscode with the WSL remote extension work
  home-manager.users.${username}.home.file.".vscode-server/server-env-setup".text = "PATH=$PATH:/run/current-system/sw/bin/";
}
