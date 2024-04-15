{
  pkgs,
  system,
  username,
  ...
}:
{
  home-manager.users.${username} = {
    programs.neovim = {
      enable = true;
      defaultEditor = true;
      vimAlias = true;
      vimdiffAlias = true;
    };
  };
}
