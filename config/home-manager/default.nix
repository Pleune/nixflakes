{
  lib,
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
    ./core/nix
    ./core/gpg
    ./services/apt-cacher-ng
    ./graphical/chromium
    ./graphical/firefox
    ./graphical/keepassxc
    ./graphical/zed-editor
    ./graphical/fonts
    ./terminal/tmux
    ./terminal/starship
    ./terminal/shell
    ./terminal/git
    ./terminal/podman
    ./terminal/neovim
    ./terminal/pi-agent
    ./theme/wsl
    ./theme/gnome
  ];
}
