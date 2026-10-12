{ lib, pkgs, ... }:
{
  programs.nvf.settings.vim = {
    fzf-lua.enable = true;

    git = {
      enable = true;
      gitsigns.mappings = {
        nextHunk = "]h";
        previousHunk = "[h";
        previewHunk = "<leader>hp";
        toggleBlame = "<leader>hB";
      };
    };

    lsp.trouble = {
      enable = true;
      mappings = {
        workspaceDiagnostics = "<leader>xx";
        documentDiagnostics = "<leader>xX";
        symbols = "<leader>cs";
        lspReferences = "<leader>cl";
        locList = "<leader>xL";
        quickfix = "<leader>xQ";
      };
    };

    mini = {
      ai.enable = true;
      bracketed.enable = true;
      bufremove.enable = true;
      comment.enable = true;
      files.enable = true;
      icons.enable = true;
      indentscope.enable = true;
      misc.enable = true;
      operators = {
        enable = true;
        # The default gx prefix would hide Neovim's open-URL gx.
        setupOpts.exchange.prefix = "cx";
      };
      pairs.enable = true;
      statusline.enable = true;
      surround.enable = true;
      tabline.enable = true;

      hipatterns = {
        enable = true;
        setupOpts.highlighters = {
          fixme = {
            pattern = "%f[%w]()FIXME()%f[%W]";
            group = "MiniHipatternsFixme";
          };
          hack = {
            pattern = "%f[%w]()HACK()%f[%W]";
            group = "MiniHipatternsHack";
          };
          todo = {
            pattern = "%f[%w]()TODO()%f[%W]";
            group = "MiniHipatternsTodo";
          };
          note = {
            pattern = "%f[%w]()NOTE()%f[%W]";
            group = "MiniHipatternsNote";
          };
          hex_color = lib.generators.mkLuaInline "require('mini.hipatterns').gen_highlighter.hex_color()";
        };
      };
    };

    lazy.plugins = {
      "auto-session" = {
        package = pkgs.vimPlugins.auto-session;
        setupModule = "auto-session";
        setupOpts = {
          auto_save = true;
          auto_restore = true;
          suppressed_dirs = [
            "~/"
            "~/Downloads"
            "~/Documents"
            "~/Desktop/"
            "~/tmp"
            "/tmp"
          ];
          post_restore_cmds = [ "silent! edit" ];
        };
      };
      "vim-tmux-navigator".package = pkgs.vimPlugins.vim-tmux-navigator;
      "smartyank.nvim".package = pkgs.vimPlugins.smartyank-nvim;
    };

    keymaps = [
      {
        mode = "n";
        key = "<leader>ff";
        action = "<cmd>FzfLua files<CR>";
        desc = "FzfLua files";
      }
      {
        mode = "n";
        key = "<leader>fg";
        action = "<cmd>FzfLua git_status<CR>";
        desc = "FzfLua git modified files";
      }
      {
        mode = "n";
        key = "<leader>fr";
        action = "<cmd>FzfLua oldfiles<CR>";
        desc = "FzfLua recent files";
      }
      {
        mode = "n";
        key = "<leader>fc";
        action = "<cmd>FzfLua grep_curbuf<CR>";
        desc = "FzfLua find in file";
      }
      {
        mode = "n";
        key = "<leader>fs";
        action = "<cmd>FzfLua live_grep<CR>";
        desc = "FzfLua live grep";
      }
      {
        mode = "n";
        key = "<leader>fb";
        action = "<cmd>FzfLua buffers<CR>";
        desc = "FzfLua buffers";
      }
      {
        mode = "n";
        key = "<leader>fk";
        action = "<cmd>FzfLua keymaps<CR>";
        desc = "FzfLua keymaps";
      }

      {
        mode = "n";
        key = "<leader>wr";
        action = "<cmd>AutoSession restore<CR>";
        desc = "Restore session for cwd";
      }
      {
        mode = "n";
        key = "<leader>ws";
        action = "<cmd>AutoSession save<CR>";
        desc = "Save session for cwd";
      }

      {
        mode = [
          "o"
          "x"
        ];
        key = "ih";
        action = ":<C-U>Gitsigns select_hunk<CR>";
        desc = "Select hunk";
      }

      {
        mode = "n";
        key = "<leader>bx";
        action = "MiniBufremove.delete";
        lua = true;
        desc = "Close buffer";
      }
      {
        mode = "n";
        key = "<leader>e";
        action = ''
          function(...)
            if not MiniFiles.close() then MiniFiles.open(...) end
          end
        '';
        lua = true;
        desc = "Open file explorer";
      }
      {
        mode = "n";
        key = "<leader>sm";
        action = "MiniMisc.zoom";
        lua = true;
        desc = "Maximize or restore window";
      }
    ];
  };
}
