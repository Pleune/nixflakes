{ pkgs, ... }:
{
  vimAlias = true;

  colorschemes.kanagawa.enable = true;

  impureRtp = true;

  globals = {
    mapleader = " ";
    maplocalleader = " ";
  };

  keymaps = [

    # Core find via telescope
    {
      options.desc = "Find files";
      mode = "n";
      options.silent = true;
      key = "<leader>ff";
      action = ":Telescope find_files<cr>";
    }
    {
      options.desc = "Find by grep";
      mode = "n";
      options.silent = true;
      key = "<leader>fg";
      action = ":Telescope live_grep<cr>";
    }
    {
      options.desc = "Find by help tags";
      mode = "n";
      options.silent = true;
      key = "<leader>fh";
      action = ":Telescope help_tags<cr>";
    }
    {
      options.desc = "Find by git files";
      mode = "n";
      options.silent = true;
      key = "<leader>fG";
      action = ":Telescope git_files<cr>";
    }
    {
      options.desc = "Find buffer";
      mode = "n";
      options.silent = true;
      key = "<leader><space>";
      action = ":Telescope buffers<cr>";
    }
    {
      options.desc = "Find in buffer";
      mode = "n";
      options.silent = true;
      key = "<leader>/";
      action = ":Telescope current_buffer_fuzzy_find<cr>";
    }
    {
      options.desc = "Neoclip select";
      mode = "n";
      options.silent = true;
      key = "P";
      action = ":Telescope neoclip<cr>";
    }

    # Open file tree window
    {
      options.desc = "Open filetree (root)";
      mode = "n";
      options.silent = true;
      key = "<leader>e";
      action = ":Neotree toggle reveal_force_cwd<cr>";
    }
    {
      options.desc = "Open filetree (cwd)";
      mode = "n";
      options.silent = true;
      key = "<leader>E";
      action = ":Neotree toggle<cr>";
    }

    # Toggleterm
    {
      options.desc = "Open Terminal";
      mode = "n";
      options.silent = true;
      key = "<leader>T";
      action = ":ToggleTerm<cr>";
    }

    # LazyGit
    {
      options.desc = "Open LazyGit";
      mode = "n";
      options.silent = true;
      key = "<leader>g";
      action = ":LazyGit<cr>";
    }

    # random diagnostic
    {
      options.desc = "Show diagnostic";
      mode = "n";
      key = "<leader>d";
      action.__raw = "vim.diagnostic.open_float";
    }

    # reload from last time
    {
      options.desc = "Load directory";
      mode = "n";
      key = "<leader>pl";
      action.__raw = "function() require('persistence').load() end";
    }
    {
      options.desc = "Load last";
      mode = "n";
      key = "<leader>pL";
      action.__raw = "function() require('persistence').load({ last = true }) end";
    }
    {
      options.desc = "select";
      mode = "n";
      key = "<leader>ps";
      action.__raw = "function() require('persistence').select() end";
    }
    {
      options.desc = "Persistance quit";
      mode = "n";
      key = "<leader>pq";
      action.__raw = "function() require('persistence').stop() end";
    }

    {
      options.desc = "LaTeX preview";
      mode = "n";
      key = "<leader>l";
      action = ":TeXpresso %<cr>";
    }

    # {
    #   options.desc = "Show diagnostic";
    #   mode = "n";
    #   key = "[d";
    #   action.__raw = "vim.diagnostic.goto_prev";
    # }
    # {
    #   options.desc = "Show diagnostic";
    #   mode = "n";
    #   key = "]d";
    #   action.__raw = "vim.diagnostic.goto_next";
    # }
  ];

  keymapsOnEvents = {
    # make moving in and out of Toggle Term easier when not closing it
    TermOpen = [
      {
        mode = "t";
        key = "<esc>";
        action = ''<C-\><C-n>'';
      }
      {
        mode = "t";
        key = "jk";
        action = ''<C-\><C-n>'';
      }
      {
        mode = "t";
        key = "<C-h>";
        action = "<Cmd>wincmd h<CR>";
      }
      {
        mode = "t";
        key = "<C-j>";
        action = "<Cmd>wincmd j<CR>";
      }
      {
        mode = "t";
        key = "<C-k>";
        action = "<Cmd>wincmd k<CR>";
      }
      {
        mode = "t";
        key = "<C-l>";
        action = "<Cmd>wincmd l<CR>";
      }
      {
        mode = "t";
        key = "<C-w>";
        action = ''<C-\><C-n>'';
      }
    ];

    LspAttach = [
      {
        key = "<leader>LF";
        action.__raw = "vim.lsp.buf.format";
        options.desc = "Format buffer";
      }
      {
        key = "<leader>LR";
        action.__raw = "vim.lsp.buf.rename";
        options.desc = "Rename symbol";
      }
      {
        key = "<leader>Ld";
        action.__raw = "vim.lsp.buf.definition";
        options.desc = "Goto definiton";
      }
      {
        key = "<leader>LD";
        action.__raw = "vim.lsp.buf.type_definition";
        options.desc = "Goto type definiton";
      }
      {
        key = "<leader>Ll";
        action.__raw = "vim.lsp.buf.declaration";
        options.desc = "Goto declaration";
      }
      {
        key = "<leader>Li";
        action.__raw = "vim.lsp.buf.implementation";
        options.desc = "Goto definiton";
      }
      {
        key = "<leader>La";
        action.__raw = "vim.lsp.buf.code_action";
        options.desc = "Code Action";
      }
      {
        key = "<leader>Lr";
        action.__raw = "require('telescope.builtin').lsp_references";
        options.desc = "View references";
      }
      {
        key = "<leader>Ls";
        action.__raw = "require('telescope.builtin').lsp_document_symbols";
        options.desc = "View document symbols";
      }
      {
        key = "<leader>LS";
        action.__raw = "require('telescope.builtin').lsp_workspace_symbols";
        options.desc = "View workspace symbols";
      }
      {
        # Hover
        key = "K";
        action.__raw = "vim.lsp.buf.hover";
        options.desc = "Hover Documentation";
      }
      {
        key = "<leader>Lk";
        action.__raw = "vim.lsp.buf.signature_help";
        options.desc = "Signature Documentation";
      }
    ];
  };

  plugins = {
    ltex-extra = {
      enable = true;
      settings.path = "~/.cache/nvim/";
    };
    web-devicons.enable = true;
    direnv.enable = true;
    fidget.enable = true; # LSP notifications
    gitblame.enable = true;
    headlines.enable = true; # better markdown rendering
    hex.enable = true; # binary file mode
    # image = { # idk does not work in wsl
    #   enable = true;
    #   backend = "ueberzug"; # support more than just kitty term
    # };
    persistence.enable = true;
    ledger.enable = true; # literally accounting
    neoclip.enable = true;
    spider.enable = true;
    texpresso.enable = true;
    trim.enable = true;
    lazygit = {
      enable = true;
      settings = {
        floating_window_scaling_factor = 0.9;
        use_neovim_remote = 1; # faster startup
      };
    };
    which-key = {
      enable = true;
      settings.spec = [
        {
          __unkeyed-1 = "<leader>f";
          group = "Find";
        }
        {
          __unkeyed-1 = "<leader>L";
          group = "Language";
        }
        {
          __unkeyed-1 = "<leader>p";
          group = "Persistance";
        }
      ];
    };
    fugitive.enable = true;
    sleuth.enable = true;
    comment.enable = true;
    gitsigns.enable = true;
    lualine = {
      enable = true;
      settings.options = {
        iconsEnabled = true;
        theme = "onedark";
        extensions = [ "fzf" ];
        # sectionSeparators.left = "";
        # sectionSeparators.right = "";
        # componentSeparators.left = "|";
        # componentSeparators.right = "|";
      };
    };
    barbecue.enable = true;
    trouble.enable = true;
    indent-blankline.enable = true;
    guess-indent.enable = true;
    telescope = {
      enable = true;
      extensions = {
        fzy-native = {
          enable = true;
          settings = {
            #case_mode = "smart_case";
            #fuzzy = true;
            override_generic_sorter = true;
            override_file_sorter = false; # frency
          };
        };
        media-files.enable = true;
        ui-select.enable = true;
        frecency.enable = true;
        file-browser = {
          enable = true;
          settings.hijack_netrw = true;
        };
      };
    };
    treesitter = {
      enable = true;
      settings = {
        indent.enable = true;
        ensure_installed = "all";
        highlight = {
          enable = true;

          # prefer vimtex highlighting over treesitter,
          # even though it uses the legacy system
          disable = [ "latex" ];
          additional_vim_regex_highlighting = [
            "latex"
            "markdown"
          ];
        };
      };
    };
    neo-tree = {
      enable = true;
      settings = {
        close_if_last_window = true;
        enable_git_status = true;
        enable_modified_markers = true;
        enable_refresh_on_write = true;
        buffers = {
          bind_to_cwd = false;
          follow_current_file = {
            enabled = true;
          };
        };
      };
    };
    leap.enable = true;
    toggleterm.enable = true;

    vimtex = {
      enable = true;
      settings.view_method = "zathura";
      texlivePackage = pkgs.texlive.combined.scheme-full; # TODO: replace with medium in flake export
    };

    intellitab.enable = true;
    cmp = {
      enable = true;
      settings = {
        sources = [
          { name = "spell"; }
          { name = "async_path"; }
          { name = "fish"; }
          { name = "nvim_lsp"; }
          { name = "buffer"; }
          { name = "treesitter"; }
          #{ name = "snippy"; }
          { name = "luasnip"; }
          { name = "latex-symbols"; }
          { name = "nvim_lsp_signature_help"; }
        ];

        # Tab style snippet mapping, where by default nothing
        # is selected. Tab cycles through completions, while
        # automatically applying them, however snippets require
        # enter to expand.
        #snippet.expand = ''function(args) require('snippy').expand_snippet(args.body); end'';
        snippet.expand = ''function(args) require'luasnip'.lsp_expand(args.body); end'';
        mapping = {
          "<C-p>" = "cmp.mapping.select_prev_item()";
          "<C-n>" = "cmp.mapping.select_next_item()";
          "<C-d>" = "cmp.mapping.scroll_docs(-4)";
          "<C-f>" = "cmp.mapping.scroll_docs(4)";
          "<C-e>" = "cmp.mapping.close()";
          "<C-Space>" = ''
            cmp.mapping(function(fallback)
              if cmp.visible() then
                if require("luasnip").expandable_or_jumpable() then
                  require("luasnip").expand_or_jump()
                else
                  cmp.confirm({
                      select = true,
                      behavior = cmp.ConfirmBehavior.Insert
                  })
                end
              else
                cmp.complete()
              end
            end)'';
          "<Tab>" = ''
            cmp.mapping(function(fallback)
              if cmp.visible() then
                cmp.select_next_item()
              elseif require("luasnip").locally_jumpable(1) then
                require("luasnip").jump(1)
              else
                require("intellitab").indent()
                -- fallback()
              end
            end, { "i", "s" })'';

          "<S-Tab>" = ''
            cmp.mapping(function(fallback)
              if cmp.visible() then
                cmp.select_prev_item()
              elseif require("luasnip").locally_jumpable(-1) then
                require("luasnip").jump(-1)
              else
                fallback()
              end
            end, { "i", "s" })'';
        };
      };
    };
    luasnip.enable = true; # for cmp - does not auto enable

    lsp = {
      enable = true;
      servers = {
        ruff.enable = true;
        yamlls = {
          enable = true;
          settings = {
            format.enable = true;
          };
        };
        pyright = {
          enable = true;
          settings = {
            pytight.disableTaggedHints = true;
            pyright.disableOrganizeImports = true;
            python.analysis.ignore = "*";
          };
        };
        clangd.enable = true;
        lua_ls = {
          enable = true;
          settings = {
            workspace.checkThirdParty = false;
            telemetry.enable = false;
          };
        };
        cmake.enable = true;
        nil_ls = {
          enable = true;
          settings.formatting.command = [ "nixfmt" ];
        };
        dockerls.enable = true;
        texlab = {
          enable = true;
          settings.texlab = {
            local = "latexindent.yaml";
            latexindent = {
              modifyLineBreaks = true;
            };
          };
        };
        ltex = {
          enable = true; # grammar checking
          settings = {
            configurationTarget = {
              dictionary = "user";
              disabledRules = "workspaceFolderExternalFile";
              hiddenFalsePositives = "workspaceFolderExternalFile";
            };
          };
        };
      };
    };
    lsp-lines.enable = true;
    lsp-status.enable = true; # Show some lsp goodies in the lualine
    lspkind.enable = true; # Show little icons for what type things are
  };

  localOpts = {
    number = true; # Show line numbers
    signcolumn = "yes";
  };

  opts = {
    mouse = "a"; # enable mouse mode
    clipboard = "unnamedplus"; # enable copy paste
    breakindent = true;
    undofile = true;
    ignorecase = true;
    smartcase = true;
    updatetime = 200;
    timeout = true;
    timeoutlen = 300;
    completeopt = "menuone,noselect";
    termguicolors = true;
  };

  performance = {
    combinePlugins.enable = true;
    byteCompileLua.enable = true;
  };
}
