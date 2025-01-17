{
  username,
  nixpkgs,
  ...
}:
{
  imports = [ "${nixpkgs}/nixos/modules/virtualisation/proxmox-lxc.nix" ];

  time.timeZone = "America/Detroit";
  i18n.defaultLocale = "en_US.UTF-8";

  home-manager.users.${username} = {
    nixflakes = {
      theme = "none";
      gui = false;
      daily = false;
    };
  };

  system.stateVersion = "23.11";
}
