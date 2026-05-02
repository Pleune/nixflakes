{
  username,
  nixpkgs,
  ...
}:
{
  imports = [ "${nixpkgs}/nixos/modules/virtualisation/proxmox-lxc.nix" ];

  nixpkgs.hostPlatform = {
    # gcc.arch = "x86-64-v3";
    # gcc.tune = "alderlake";
    system = "x86_64-linux";
  };

  time.timeZone = "America/Detroit";
  i18n.defaultLocale = "en_US.UTF-8";

  home-manager.users.${username} = {
    nixflakes = {
      theme.name = "none";
      gui = false;
    };
  };

  system.stateVersion = "23.11";
}
