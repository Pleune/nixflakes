{
  lib,
  config,
  pkgs,
  ...
}:
with lib;
{
  options.nixflakes.programs.zedEditor.enable = mkEnableOption "Zed editor";

  config = mkIf config.nixflakes.programs.zedEditor.enable {
    programs.zed-editor = {
      enable = true;
      package = pkgs.zed-editor;
      extraPackages = with pkgs; [
        nil
        nixd
        nixfmt
        libxml2
      ];
      extensions = [
        "asciidoc"
        "basher"
        "csv"
        "docker-compose"
        "dockerfilev"
        "env"
        "fish"
        "git-firefly"
        "glsl"
        "html"
        "ini"
        "latex"
        "lua"
        "make"
        "mermaid"
        "neocmake"
        "nix"
        "proto"
        "rainbow-csv"
        "scss"
        "ssh-config"
        "typos"
        "0x96f"
        "material-icon-theme"
      ];

      userSettings = {
        vim_mode = true;
        file_icons = true;
        load_direnv = "direct";
        window_decorations = "server";
        auto_update = false;
        hide_mouse = "never";

        buffer_font_family = "Iosevka Nerd Font Mono";
        ui_font_fallbacks = [
          "Nerd Font"
          "Noto Mono"
          "Monospace"
        ];
        buffer_font_features = {
          calt = true;
        };

        title_bar = {
          show_onboarding_banner = false;
          show_user_picture = false;
          show_sign_in = false;
        };

        project_panel = {
          dock = "left";
          auto_reveal_entries = false;
          hide_hidden = true;
          auto_open.on_drop = false;
          hide_gitignore = true;
        };

        debug_panel = {
          dock = "right";
        };

        telemetry = {
          diagnostics = false;
          metrics = false;
        };

        terminal = {
          line_height = "standard";
        };

        lsp = {
          nil.settings.nix.flake = {
            autoArchive = true;
            autoEvalInputs = true;
          };
        };

        languages.XML = {
          format_on_save = "off";
          tab_size = 2;
          formatter.external = {
            command = "xmllint";
            arguments = [
              "--format"
              "--encode"
              "UTF-8"
              "-"
            ];
          };
        };
      };
    };
  };
}
