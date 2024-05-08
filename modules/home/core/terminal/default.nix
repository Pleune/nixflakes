{
  pkgs,
  username,
  userFullName,
  userEmail,
  ...
}:
{
  imports = [
    ./nvim
    ./tmux
    ./starship
  ];

  home-manager.users.${username} = {
    programs = {
      git = {
        enable = true;
        lfs.enable = true;
        userName = userFullName;
        userEmail = userEmail;
        delta = {
          enable = true;
          options = {
            navigate = true;
            side-by-side = true;
          };
        };
      };

      zoxide = {
        enable = true;
        enableFishIntegration = true;
      };

      fzf = {
        enable = true;
        enableFishIntegration = true;
      };

      vim.enable = true;
      bash = {
        enable = true;
        initExtra = ''
          if [[ $(${pkgs.procps}/bin/ps --no-header --pid=$PPID --format=comm) != "fish" && -z ''${BASH_EXECUTION_STRING} ]]
          then
            shopt -q login_shell && LOGIN_OPTION='--login' || LOGIN_OPTION=""
            export SHELL=/nix/store/032wbc8f1nb5nfc6ww2wcgvjfbrh49jn-user-environment/bin/fish
            exec $SHELL $LOGIN_OPTION
          fi
        '';
      };

      fish = {
        enable = true;
        interactiveShellInit = ''
          set fish_greeting # Disable greeting
        '';
        shellAliases = {
          # cd = "z";
        };
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

      direnv = {
        enable = true;
        nix-direnv.enable = true;
      };

      nix-index = {
        enable = true;
        enableFishIntegration = true;
      };
    };

    services.gpg-agent.enableFishIntegration = true;

    home.packages = with pkgs; [
      grc
      gh
      ripgrep
      btop
      todoist
      zip
      unzip
      wget
      curl
      nixfmt-rfc-style
      git-subrepo
      tldr
      bat
    ];
  };
}
