{
  lib,
  pkgs,
  nixosStateVersion ? null,
  ...
}:
with lib;
{
  # core options for all modules to use
  options.nixflakes = {
    gui = mkEnableOption "preset default gui options";
    theme = {
      name = mkOption { default = "none"; };
      installGnomeExtensions = mkOption { default = true; };
    };
  };

  config = {
    # when home-manager is pulled in through nixos, just set the state version to default to the system one. standalone home manager configs will still need to set this.
    home.stateVersion = mkDefault nixosStateVersion;
  };

  imports = [
    ./core/nix.nix
    ./core/gpg.nix
    ./services/apt-cacher-ng.nix
    ./graphical/chromium.nix
    ./graphical/firefox.nix
    ./graphical/keepassxc.nix
    ./graphical/zed-editor.nix
    ./graphical/fonts.nix
    ./terminal/tmux.nix
    ./terminal/starship.nix
    ./terminal/shell.nix
    ./terminal/git.nix
    ./terminal/podman.nix
    ./terminal/neovim.nix
    ./theme/wsl.nix
    ./theme/gnome.nix
  ];
}
