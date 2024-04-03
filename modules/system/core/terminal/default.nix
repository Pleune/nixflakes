{ pkgs, home-manager, username, ... }: {

  programs = {
    htop.enable = true;
    mtr.enable = true;
    bash = {
      loginShellInit = ''
        nitch
      '';
    };
  };

  environment.systemPackages = with pkgs; [
    htop
    git
    curl
    nitch
    zip
    unzip
    wget
  ];
}
