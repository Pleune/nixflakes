{ pkgs, ... }:
{
  programs = {
    htop.enable = true;
    mtr.enable = true;
  };

  environment.systemPackages = with pkgs; [
    git
    curl
    zip
    unzip
    wget
  ];
}
