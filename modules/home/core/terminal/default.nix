{ pkgs, home-manager, username, ... }: {
  imports = [ ./nvim ./tmux ./starship ];

  home-manager.users.${username} = {
    programs.git.enable = true;
    programs.vim.enable = true;
    programs.bash = {
      enable = true;
      initExtra = ''
        if [[ $(${pkgs.procps}/bin/ps --no-header --pid=$PPID --format=comm) != "fish" && -z ''${BASH_EXECUTION_STRING} ]]
        then
          shopt -q login_shell && LOGIN_OPTION='--login' || LOGIN_OPTION=""
          exec ${pkgs.fish}/bin/fish # $LOGIN_OPTION
        fi
      '';
    };

    programs.fish = {
      enable = true;
      interactiveShellInit = ''
          set fish_greeting # Disable greeting
        '';
      plugins = [
        {
          name = "z";
          src = pkgs.fishPlugins.z.src;
        }
        {
          name = "bass";
          src = pkgs.fishPlugins.bass.src;
        }
        {
          name = "colored-man-pages";
          src = pkgs.fishPlugins.colored-man-pages.src;
        }
        {
          name = "sponge";
          src = pkgs.fishPlugins.sponge.src;
        }
        {
          name = "pisces";
          src = pkgs.fishPlugins.pisces.src;
        }
        {
          name = "grc";
          src = pkgs.fishPlugins.grc.src;
        }
      ];

      functions = {
        develop = {
	  wraps = "nix develop";
	  body = "nix develop --command fish";
	};
      };
    };

    programs.direnv = {
      enable = true;
      nix-direnv.enable = true;
    };

    home.packages = with pkgs; [ grc gh ripgrep btop todoist zip unzip wget curl bash ];
  };
}
