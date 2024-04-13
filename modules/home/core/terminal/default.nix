{ pkgs, home-manager, username, userFullName, userEmail, ... }: {
  imports = [ ./nvim ./tmux ./starship ];

  home-manager.users.${username} = {
    programs.git = {
      enable = true;
      userName = userFullName;
      userEmail = userEmail;
    };

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
        cmake = {
          wraps = "cmake";
          body = ''
              # Exit early if not a configure type command
              set identifiers --build --install --open -P -E --find-package --workflow --help -DCMAKE_EXPORT_COMPILE_COMMANDS
              for i in $identifiers
                if string match -q -e -- $i $argv 
                  command cmake $argv
                  return
                end
              end
              
              # default to generate a compile_commands.json
              if not string match -q -e -- CMAKE_EXPORT_COMPILE_COMMANDS
                set -a argv -DCMAKE_EXPORT_COMPILE_COMMANDS=1
              end
              
              # default to using Ninja
              if type -q ninja; and not string match -q -e -- -G
                set -a argv -G Ninja
              end

              command cmake $argv
            '';
        };
      };
    };

    programs.direnv = {
      enable = true;
      nix-direnv.enable = true;
    };

    home.packages = with pkgs; [ grc gh ripgrep btop todoist zip unzip wget curl nixpkgs-fmt git-subrepo ];
  };
}
