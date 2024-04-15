{
  pkgs,
  username,
  ...
}:
{
  imports = [ ../../core/terminal/nvim ]; # enabled and default editor
  home-manager.users.${username}.programs.neovim = {
    withRuby = true;
    withNodeJs = true;
    withPython3 = true;
    extraPython3Packages = (pkgs: with pkgs; [ python-lsp-server ]);
    extraLuaConfig = ''
      ${builtins.readFile ./init.lua}
    '';
    extraPackages = with pkgs; [
      fzf
      gcc
      nil
      dockerfile-language-server-nodejs
      lua-language-server
    ];
  };
}
