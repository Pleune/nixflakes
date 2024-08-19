{
  username,
  packages,
  lib,
  config,
  pkgs,
  ...
}:
with lib;
{
  options = {
    nixflakes.programs.mitchvim = {
      enable = mkEnableOption "Mitch neovim";
      defaultEditor = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Whether to configure {command}`nvim` as the default
          editor using the {env}`EDITOR` environment variable.
        '';
      };
      vimAlias = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Symlink {command}`vim` to {command}`nvim` binary.
        '';
      };
      viAlias = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Symlink {command}`vi` to {command}`nvim` binary.
        '';
      };
      vimdiffAlias = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Alias {command}`vimdiff` to {command}`nvim -d`.
        '';
      };
    };
  };

  config =
    let
      cfg = config.nixflakes.programs.mitchvim;
    in
    {
      home-manager.users.${username} = mkIf cfg.enable (mkMerge [
        {
          home.packages = [
            (pkgs.symlinkJoin {
              name = "mitchvim-hm";
              paths = [
                packages.mitchvim
                (pkgs.runCommandLocal "nvim-vim-alias" { buildInputs = [ pkgs.makeBinaryWrapper ]; } (
                  ''
                    mkdir -p $out/bin
                  ''
                  + (lib.optionalString cfg.vimAlias ''
                    ln -s nvim $out/bin/vim
                  '')
                  + (lib.optionalString cfg.viAlias ''
                    ln -s nvim $out/bin/vi
                  '')
                  + (lib.optionalString cfg.vimdiffAlias ''
                    makeWrapper ${packages.mitchvim}/bin/nvim $out/bin/vimdiff --add-flags -d
                  '')
                ))
              ];
            })
          ];

          home.sessionVariables = mkIf cfg.defaultEditor { EDITOR = "nvim"; };
        }
      ]);
    };
}
