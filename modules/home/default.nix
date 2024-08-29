{ lib, ... }:
with lib; {
  # core options for all modules to use
  options.nixflakes = {
    gui = mkEnableOption "preset default gui options";
    daily = mkEnableOption "preset applications and configs for daily use";
    games = mkEnableOption "preset applications and configs for gaming";
  };

  config = {
    nixflakes = {
      gui = mkDefault true;
      daily = mkDefault true;
      programs.mitchvim.enable = true;
      gpg = true;
    };
  };

  imports = [
    ./core
    ./apps
    ./theme
  ];
}
