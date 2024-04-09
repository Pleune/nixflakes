{ pkgs, system, username, ... }: {
  imports = [ ../../core/terminal/nvim ]; # enabled and default editor
  home-manager.users.${username} = {
    programs.neovim = {
      withRuby = true;
      withNodeJs = true;
      withPython3 = true;
      extraPython3Packages = (ps: with ps; [ python-lsp-server ]);
      extraLuaConfig = ''
        ${builtins.readFile ./init.lua}
      '';
    };
    home.packages = [ pkgs.fzf pkgs.gcc ];
  };
}
