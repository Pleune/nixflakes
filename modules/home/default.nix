{ lib, nixosStateVersion ? null, ... }:
with lib; {
  # core options for all modules to use
  options.nixflakes = {
    gui = mkEnableOption "preset default gui options";
    daily = mkEnableOption "preset applications and configs for daily use";
    games = mkEnableOption "preset applications and configs for gaming";
  };

  config = {
    nixflakes = {
      gui = mkDefault false;
      daily = mkDefault false;
      programs.mitchvim.enable = mkDefault false;
      gpg = mkDefault false;
    };

    # when home-manager is pulled in through nixos, just set the state version to default to the system one. standalone home manager configs will still need to set this.
    home.stateVersion = mkDefault nixosStateVersion;
  };

  imports = [
    ./core
    ./apps
    ./theme
  ];
}
