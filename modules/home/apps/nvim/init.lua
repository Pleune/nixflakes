--[[

apt install build-essential cmake fzf clangd
python3 -m pip install python-language-server

--]]

-- Use space as the meta key
vim.g.mapleader = ' '
vim.g.maplocalleader = ' '

-- Dsable netrw fr nvim-tree
vim.g.loaded_netrw = 1
vim.g.loaded_netrwPlugin = 1

-- Install package manager
--    https://github.com/folke/lazy.nvim
--    `:help lazy.nvim.txt` for more info
local lazypath = vim.fn.stdpath 'data' .. '/lazy/lazy.nvim'
if not vim.loop.fs_stat(lazypath) then
  vim.fn.system {
    'git',
    'clone',
    '--filter=blob:none',
    'https://github.com/folke/lazy.nvim.git',
    '--branch=stable', -- latest stable release
    lazypath,
  }
end
vim.opt.rtp:prepend(lazypath)

-- install plugins from github
require('lazy').setup({
  'tpope/vim-fugitive',                       -- for git
  'tpope/vim-rhubarb',                        -- for git
  'tpope/vim-sleuth',                         -- autodetect indentation
  'editorconfig/editorconfig-vim',            -- support editorconfig files
  { 'folke/which-key.nvim',  config = true }, -- Useful plugin to show you pending keybinds.
  { 'numToStr/Comment.nvim', config = true },

  { -- language servers
    'neovim/nvim-lspconfig',
    dependencies = {
      { 'j-hui/fidget.nvim', tag = 'legacy', config = true }, -- lsp info in bottom right
      { 'folke/neodev.nvim', config = true },                 -- complete for nvim lua configuration
      'nvim-telescope/telescope.nvim'                         -- configured below
    },
    config = function()
      -- Setup language servers.
      local lspconfig = require('lspconfig')

      -- pip install python-language-server
      -- lspconfig.pylsp.setup {
      --   settings = {
      --     pylsp = {
      --       plugins = {
      --         black = {
      --           enabled = true
      --         }
      --       }
      --     }
      --   }
      -- }

      -- lspconfig.pylsp.setup {
      --   settings = {
      --     pylsp = {
      --       plugins = {
      --         -- disable functionality given by ruff
      --         autopep8 = { enabled = false },
      --         flake8 = { enabled = false },
      --         pyflakes = { enabled = false },
      --         mccabe = { enabled = false },
      --         pycodestyle = { enabled = false }
      --       }
      --     }
      --   }
      -- }
      lspconfig.ruff_lsp.setup {}
      lspconfig.pyright.setup {
        settings = {
          pyright = {
            disableTaggedHints = true,
            disableOrganizeImports = true,
          },
          python = {
            analysis = {
              ignore = { "*" },
            }
          }
        }
      }

      -- apt install clangd-?? and symlink to clangd on path
      lspconfig.clangd.setup {}

      lspconfig.lua_ls.setup {
        settings = {
          Lua = {
            workspace = { checkThirdParty = false },
            telemetry = { enable = false },
          }
        }
      }

      lspconfig.cmake.setup {}

      lspconfig.nil_ls.setup {
        settings = {
          ['nil'] = {
            formatting = {
              command = { "nixfmt" }
            }
          }
        }
      }

      -- npm install -g dockerfile-language-server-nodejs
      lspconfig.dockerls.setup {}

      vim.keymap.set('n', '<space>e', vim.diagnostic.open_float)
      vim.keymap.set('n', '[d', vim.diagnostic.goto_prev)
      vim.keymap.set('n', ']d', vim.diagnostic.goto_next)
      vim.keymap.set('n', '<space>q', vim.diagnostic.setloclist)

      -- Use LspAttach autocommand to only map the following keys
      -- after the language server attaches to the current buffer
      vim.api.nvim_create_autocmd('LspAttach', {
        group = vim.api.nvim_create_augroup('UserLspConfig', {}),
        callback = function(ev)
          -- Enable completion triggered by <c-x><c-o>
          vim.bo[ev.buf].omnifunc = 'v:lua.vim.lsp.omnifunc'

          local nmap = function(keys, func, desc)
            if desc then
              desc = 'LSP: ' .. desc
            end
            vim.keymap.set('n', keys, func, { buffer = ev.buf, desc = desc })
          end

          nmap('<leader>F', vim.lsp.buf.format, 'Format')
          nmap('<leader>R', vim.lsp.buf.rename, 'Rename')
          nmap('<leader>C', vim.lsp.buf.code_action, 'Code action')

          nmap('gd', vim.lsp.buf.definition, 'Goto definition')
          nmap('gr', require('telescope.builtin').lsp_references, 'Goto References')
          nmap('gI', vim.lsp.buf.implementation, 'Goto implementation')
          nmap('<leader>D', vim.lsp.buf.type_definition, 'Type definition')
          nmap('<leader>ds', require('telescope.builtin').lsp_document_symbols, 'Document symbols')
          nmap('<leader>ws', require('telescope.builtin').lsp_dynamic_workspace_symbols, 'Workspace symbols')

          -- See `:help K` for why this keymap
          nmap('K', vim.lsp.buf.hover, 'Hover Documentation')
          nmap('<C-k>', vim.lsp.buf.signature_help, 'Signature Documentation')

          -- Lesser used LSP functionality
          nmap('gD', vim.lsp.buf.declaration, 'Goto Declaration')
          nmap('<leader>wa', vim.lsp.buf.add_workspace_folder, 'Workspace Add Folder')
          nmap('<leader>wr', vim.lsp.buf.remove_workspace_folder, 'Workspace Remove Folder')
          nmap('<leader>wl', function()
            print(vim.inspect(vim.lsp.buf.list_workspace_folders()))
          end, 'Workspace list Folders')
        end,
      })
    end
  },

  { -- autocomplete
    'hrsh7th/nvim-cmp',
    dependencies = {
      'dcampos/nvim-snippy',
      'dcampos/cmp-snippy',
      'honza/vim-snippets',
      'rafamadriz/friendly-snippets',
      'nvim-treesitter/nvim-treesitter', -- configured elsewhere
      {
        'hrsh7th/cmp-nvim-lsp',
        config = function() -- Tell LSP about completion capabilities
          local capabilities = vim.lsp.protocol.make_client_capabilities()
          capabilities = require('cmp_nvim_lsp').default_capabilities(capabilities)
        end
      },
    },
    config = function()
      local cmp = require 'cmp'
      local snippy = require 'snippy'

      local has_words_before = function()
        unpack = unpack or table.unpack
        local line, col = unpack(vim.api.nvim_win_get_cursor(0))
        return col ~= 0 and vim.api.nvim_buf_get_lines(0, line - 1, line, true)[1]:sub(col, col):match("%s") == nil
      end

      cmp.setup {
        snippet = {
          expand = function(args)
            require('snippy').expand_snippet(args.body)
          end,
        },

        window = {
          completion = cmp.config.window.bordered(),
          documentation = cmp.config.window.bordered(),
        },

        enabled = function()
          local context = require 'cmp.config.context'
          if vim.api.nvim_get_mode().mode == 'c' then
            return true
          else
            return not context.in_treesitter_capture("comment")
                and not context.in_syntax_group("Comment")
          end
        end,

        mapping = {
          ["<Tab>"] = cmp.mapping(function(fallback)
            if cmp.visible() then
              cmp.select_next_item()
            elseif snippy.can_expand_or_advance() then
              snippy.expand_or_advance()
            elseif has_words_before() then
              cmp.complete()
            else
              fallback()
            end
          end, { "i", "s" }),
          ["<S-Tab>"] = cmp.mapping(function(fallback)
            if cmp.visible() then
              cmp.select_prev_item()
            elseif snippy.can_jump(-1) then
              snippy.previous()
            else
              fallback()
            end
          end, { "i", "s" }),
          ['<CR>'] = cmp.mapping(function(fallback)
            if snippy.can_expand() then
              snippy.expand()
            else
              fallback()
            end
          end, { 'i', 's' }),
        },

        sources = cmp.config.sources({
          { name = 'nvim_lsp' },
          { name = 'snippy' },
        }, {
          { name = 'buffer' },
        }),
      }
    end
  },

  {
    -- Adds git releated signs to the gutter, as well as utilities for managing changes
    'lewis6991/gitsigns.nvim',
    opts = {
      -- See `:help gitsigns.txt`
      signs = {
        add = { text = '+' },
        change = { text = '~' },
        delete = { text = '_' },
        topdelete = { text = '‾' },
        changedelete = { text = '~' },
      },
      on_attach = function(bufnr)
        vim.keymap.set('n', '<leader>gp', require('gitsigns').prev_hunk,
          { buffer = bufnr, desc = '[G]o to [P]revious Hunk' })
        vim.keymap.set('n', '<leader>gn', require('gitsigns').next_hunk, { buffer = bufnr, desc = '[G]o to [N]ext Hunk' })
        vim.keymap.set('n', '<leader>ph', require('gitsigns').preview_hunk, { buffer = bufnr, desc = '[P]review [H]unk' })
      end,
    },
  },

  {
    'folke/tokyonight.nvim',
    priority = 1000,
    config = function()
      vim.cmd.colorscheme 'tokyonight-night'
    end,
  },

  {
    -- Set lualine as statusline
    'nvim-lualine/lualine.nvim',
    -- See `:help lualine.txt`
    opts = {
      options = {
        icons_enabled = false,
        theme = 'onedark',
        component_separators = '|',
        section_separators = '',
      },
    },
  },

  { -- top location linne
    "utilyre/barbecue.nvim",
    name = "barbecue",
    version = "*",
    dependencies = {
      "SmiteshP/nvim-navic",
      "nvim-tree/nvim-web-devicons",
    },
    config = function()
      require('barbecue').setup { create_autocmd = false }
      vim.api.nvim_create_autocmd({
        "WinScrolled", -- or WinResized on NVIM-v0.9 and higher
        "BufWinEnter",
        "CursorHold",
        "InsertLeave",

        -- include this if you have set `show_modified` to `true`
        "BufModifiedSet",
      }, {
        group = vim.api.nvim_create_augroup("barbecue.updater", {}),
        callback = function()
          require("barbecue.ui").update()
        end,
      })
    end
  },

  {
    'folke/trouble.nvim',
    dependencies = {
      'nvim-tree/nvim-web-devicons'
    },
    setup = true,
    keys = {
      { '<leader>e', '<cmd>TroubleToggle<cr>', desc = 'Show Errors' },
    },
  },

  {
    -- Add indentation guides even on blank lines
    'lukas-reineke/indent-blankline.nvim',
    -- Enable `lukas-reineke/indent-blankline.nvim`
    -- See `:help indent_blankline.txt`
    main = "ibl",
    opts = {
    },
  },

  -- Fuzzy Finder (files, lsp, etc)
  {
    'nvim-telescope/telescope.nvim',
    branch = '0.1.x',
    dependencies = {
      'nvim-lua/plenary.nvim',
      {
        'nvim-telescope/telescope-fzf-writer.nvim',
      }
    },
    keys = {
      { '<leader>ff',      '<cmd>Telescope find_files<cr>',                desc = 'Find files' },
      { '<leader>fr',      '<cmd>Telescope live_grep<cr>',                 desc = 'Find by ripgrep' },
      { '<leader>fh',      '<cmd>Telescope help_tags<cr>',                 desc = 'Find help tags' },
      { '<leader>fg',      '<cmd>Telescope git_files<cr>',                 desc = 'Find git files' },
      { '<leader><space>', '<cmd>Telescope buffers<cr>',                   desc = 'Find existing buffer' },
      { '<leader>/',       '<cmd>Telescope current_buffer_fuzzy_find<cr>', desc = 'Find in current buffer' },
    },
    config = function()
      local telescope = require('telescope')
      telescope.setup({
        fzf_writer = {
          fuzzy = true,
          override_generic_sorter = true,
          override_file_sorter = true,
          case_mode = "smart_case"
        }
      })
    end
  },

  {
    -- Highlight, edit, and navigate code
    'nvim-treesitter/nvim-treesitter',
    dependencies = {
      'nvim-treesitter/nvim-treesitter-textobjects',
    },
    build = ':TSUpdate',
    config = function()
      require 'nvim-treesitter.configs'.setup({
        indent = { enable = true },
        highlight = { enable = true },
        ensure_installed = { "c", "lua", "vim", "vimdoc", "query" }
      })
    end
  },

  {
    'nvim-tree/nvim-tree.lua',
    dependencies = {
      "nvim-tree/nvim-web-devicons",
    },
    config = function()
      require('nvim-tree').setup {
        sort_by = "case_sensitive",
        view = {
          width = 45,
        },
        renderer = {
          group_empty = true,
        },
        filters = {
          dotfiles = true,
        },
        on_attach = function(bufnr)
          local api = require('nvim-tree.api')

          api.config.mappings.default_on_attach(bufnr)

          local function opts(desc)
            return { desc = 'nvim-tree: ' .. desc, buffer = bufnr, noremap = true, silent = true, nowait = true }
          end

          vim.keymap.set('n', 'P', function()
            local node = api.tree.get_node_under_cursor()
            print(node.absolute_path)
          end, opts('Print Node Path'))

          vim.keymap.set('n', 'Z', api.node.run.system, opts('Run System'))
        end
      }

      -- auto close nvim if tree is the last buffer open
      vim.api.nvim_create_autocmd("BufEnter", {
        nested = true,
        callback = function()
          if #vim.api.nvim_list_wins() == 1 and require("nvim-tree.utils").is_nvim_tree_buf() then
            vim.cmd "quit"
          end
        end
      })
    end,
    keys = {
      { '<leader>t', '<cmd>NvimTreeToggle<cr>', desc = 'Find files' },
    },
  },

  {
    'ggandor/leap.nvim',
    dependencies = {
      'tpope/vim-repeat'
    },
    config = function()
      require('leap').add_default_mappings()
    end
  },

  {
    'akinsho/toggleterm.nvim',
    config = function()
      require('toggleterm').setup()
      vim.keymap.set('t', '<esc>', [[<C-\><C-n>]])
      vim.keymap.set('t', 'jk', [[<C-\><C-n>]])
      vim.keymap.set('t', '<C-h>', [[<Cmd>wincmd h<CR>]])
      vim.keymap.set('t', '<C-j>', [[<Cmd>wincmd j<CR>]])
      vim.keymap.set('t', '<C-k>', [[<Cmd>wincmd k<CR>]])
      vim.keymap.set('t', '<C-l>', [[<Cmd>wincmd l<CR>]])
      vim.keymap.set('t', '<C-w>', [[<C-\><C-n><C-w>]])
    end,
    keys = {
      { '<leader>T', '<cmd>ToggleTerm<cr>', desc = 'Open Terminal' },
    }
  },

}, {})


vim.o.hlsearch = false          -- Set highlight on search
vim.wo.number = true            -- Make line numbers default
vim.o.mouse = 'a'               -- Enable mouse mode
vim.o.clipboard = 'unnamedplus' -- Sync clipboard between OS and Neovim.
vim.o.breakindent = true
vim.o.undofile = true           -- Save undo history
vim.o.ignorecase = true         -- Case-insensitive searching UNLESS \C or capital in search
vim.o.smartcase = true          -- Case-insensitive searching UNLESS \C or capital in search
vim.wo.signcolumn = 'yes'
vim.o.updatetime = 200          -- triggers CursorHold faster
vim.o.timeout = true
vim.o.timeoutlen = 300
vim.o.completeopt = 'menuone,noselect'
vim.o.termguicolors = true

vim.keymap.set({ 'n', 'v' }, '<Space>', '<Nop>', { silent = true })

-- Remap for dealing with word wrap
vim.keymap.set('n', 'k', "v:count == 0 ? 'gk' : 'k'", { expr = true, silent = true })
vim.keymap.set('n', 'j', "v:count == 0 ? 'gj' : 'j'", { expr = true, silent = true })

-- [[ Highlight on yank ]]
-- See `:help vim.highlight.on_yank()`
local highlight_group = vim.api.nvim_create_augroup('YankHighlight', { clear = true })
vim.api.nvim_create_autocmd('TextYankPost', {
  callback = function()
    vim.highlight.on_yank()
  end,
  group = highlight_group,
  pattern = '*',
})
