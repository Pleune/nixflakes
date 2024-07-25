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
      clang-tools
      cmake-language-server
      dockerfile-language-server-nodejs
      fzf
      gcc
      lua-language-server
      nil
      nodePackages.pyright
      ruff-lsp
      yaml-language-server
    ];
  };
}
