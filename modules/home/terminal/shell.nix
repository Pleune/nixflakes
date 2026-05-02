{ pkgs, config, ... }:
{
  programs = {
    zoxide = {
      enable = true;
      enableFishIntegration = true;
    };

    fzf = {
      enable = true;
      enableFishIntegration = true;
    };

    ripgrep-all = {
      enable = true;
    };

    bash = {
      enable = true;
      enableCompletion = true;
      initExtra = ''
        # prevent "too many open files" on nix build
        ulimit -n 4096

        # hook into fish for interactive shells
        if [[ $(${pkgs.procps}/bin/ps --no-header --pid=$PPID --format=comm) != "fish" && -z ''${BASH_EXECUTION_STRING} ]]
        then
          shopt -q login_shell && LOGIN_OPTION='--login' || LOGIN_OPTION=""
          export SHELL=${pkgs.fish}/bin/fish
          exec $SHELL $LOGIN_OPTION
        fi
      '';
    };

    fish = {
      enable = true;
      interactiveShellInit = ''
        set fish_greeting # Disable greeting
        set sponge_regex_patterns '(?:\d{1,3}\.){3}\d{1,3}'

        # don't add to history
        set -l history_blocklist \
          '^\s*(rm|reboot|shutdown|poweroff|halt|dd|ls)\b' \
          'of=/dev' \
          '/dev/sd' \
          '/dev/nvme' \
          '\brm\b.*\b-rf\b'
      '';
      shellAliases = {
        # cd = "z";
      };
      plugins = with pkgs.fishPlugins; [
        {
          name = "z";
          inherit (z) src;
        }
        {
          name = "bass";
          inherit (bass) src;
        }
        {
          name = "colored-man-pages";
          inherit (colored-man-pages) src;
        }
        {
          name = "pisces";
          inherit (pisces) src;
        }
        {
          name = "grc";
          inherit (grc) src;
        }
        {
          name = "fish-completion-sync";
          src = pkgs.fetchFromGitHub {
            owner = "pfgray";
            repo = "fish-completion-sync";
            rev = "ba70b6457228af520751eab48430b1b995e3e0e2";
            sha256 = "sha256-JdOLsZZ1VFRv7zA2i/QEZ1eovOym/Wccn0SJyhiP9hI=";
          };
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

        # for ROS2 building, makes integration with nvim better
        colcon = {
          wraps = "colcon";
          body = ''
            if string match -q -e -- build $argv
              if not string match -q -e -- CMAKE_EXPORT_COMPILE_COMMANDS
                set -a argv '--cmake-args' ' -DCMAKE_EXPORT_COMPILE_COMMANDS=1'
              end
            end
            command colcon $argv
          '';
        };

        fish_should_add_to_history = {
          description = "Filter fish history using a list of regexes (skip dangerous/noisy commands)";
          body = ''
            for r in $history_blocklist
              if string match -rq -- "$r" -- "$argv"
                return 1
              end
            end
            return 0
          '';
        };

        rgai = {
          description = "ripgrep-all + fzf + open in vim";
          body = ''
            set -l initial_query (string join " " -- $argv)
            set -l rg_prefix "rga --column --line-number --no-heading --color=always --smart-case "

            fzf --ansi --disabled --query "$initial_query" \
              --bind "start:reload:$rg_prefix {q} || true" \
              --bind "change:reload:sleep 0.1; $rg_prefix {q} || true" \
              --delimiter : \
              --preview "bat --color=always {1} --highlight-line {2}" \
              --preview-window "up,60%,border-bottom,+{2}+3/3,~3" \
              --bind "enter:become(vim {1} +{2})"
          '';
        };
      };

      binds = {
        "ctrl-g" = {
          command = "rgai";
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

    # configured into another file starship.nix
    # starship = {
    #   enableBashIntegration = false;
    #   enableFishIntegration = true;
    # };
  };

  services.gpg-agent.enableFishIntegration = config.nixflakes.gpg;

  home.packages = with pkgs; [
    bat
    btop
    curl
    grc
    nix-tree
    nixfmt
    ripgrep
    tldr
    todoist
    unzip
    wget
    zip
  ];
}
