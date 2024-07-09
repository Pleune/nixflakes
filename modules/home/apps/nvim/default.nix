{ pkgs, username, ... }:
{
  imports = [ ../../core/terminal/nvim ]; # enabled and default editor
  home-manager.users.${username}.programs.neovim = {
    withRuby = true;
    withNodeJs = true;
    withPython3 = true;
    extraLuaConfig = ''
      ${builtins.readFile ./init.lua}
    '';
    extraPackages = with pkgs; [
      ruff-lsp
      nodePackages.pyright
      fzf
      gcc
      nil
      dockerfile-language-server-nodejs
      lua-language-server
      cmake-language-server
      yaml-language-server
    ];
  };
}
