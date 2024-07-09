{ pkgs, ... }:
{
  programs = {
    htop.enable = true;
    mtr.enable = true;
  };

  environment.systemPackages = with pkgs; [
    htop
    git
    curl
    zip
    unzip
    wget
  ];
}
