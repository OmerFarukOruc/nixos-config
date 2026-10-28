{ lib, pkgs, ... }:
{
  programs.nvf.settings.vim = {
    lsp = {
      enable = true;
      lspkind.enable = true;
    };

    diagnostics = {
      enable = true;
      config.signs.text = lib.generators.mkLuaInline ''
        {
          [vim.diagnostic.severity.ERROR] = " ",
          [vim.diagnostic.severity.WARN] = " ",
          [vim.diagnostic.severity.HINT] = "󰠠 ",
          [vim.diagnostic.severity.INFO] = " ",
        }
      '';
    };

    languages.nix = {
      enable = true;
      lsp.enable = true;
      treesitter.enable = true;
      format = {
        enable = true;
        type = [ "nixfmt" ];
      };
    };
    # nil asks to archive each flake input on open; this answers no. nvf's nil
    # preset sets true, so this needs mkForce.
    lsp.servers.nil.settings.nil.nix.flake.autoArchive = lib.mkForce false;
    lsp.servers.nil.settings.nil.formatting.command = [ (lib.getExe pkgs.nixfmt) ];

    autocmds = [
      {
        event = [ "FileType" ];
        pattern = [ "nix" ];
        callback = lib.generators.mkLuaInline ''
          function()
            vim.bo.tabstop = 2
            vim.bo.shiftwidth = 2
          end
        '';
      }
    ];

    treesitter = {
      enable = true;
      autotagHtml = true;
      grammars = with pkgs.vimPlugins.nvim-treesitter.grammarPlugins; [
        bash
        c
        cmake
        cpp
        css
        csv
        diff
        dockerfile
        go
        html
        json
        lua
        make
        ninja
        python
        regex
        rust
        ssh_config
        toml
        vim
        xml
        yaml
      ];
    };

    snippets.luasnip.enable = true;

    autocomplete.nvim-cmp = {
      enable = true;
      mappings = {
        previous = "<C-k>";
        next = "<C-j>";
        scrollDocsUp = "<C-b>";
        scrollDocsDown = "<C-f>";
      };
    };
    lsp.lspkind.setupOpts = {
      maxwidth = 50;
      ellipsis_char = "...";
    };

    lazy.plugins."nvim-lsp-file-operations" = {
      package = pkgs.vimPlugins.nvim-lsp-file-operations;
      setupModule = "lsp-file-operations";
    };

    keymaps = [
      {
        mode = "n";
        key = "gR";
        action = "<cmd>FzfLua lsp_references<CR>";
        desc = "Show LSP references";
      }
      {
        mode = "n";
        key = "gD";
        action = "vim.lsp.buf.declaration";
        lua = true;
        desc = "Go to declaration";
      }
      {
        mode = "n";
        key = "gd";
        action = "<cmd>FzfLua lsp_definitions<CR>";
        desc = "Show LSP definitions";
      }
      {
        mode = "n";
        key = "gi";
        action = "<cmd>FzfLua lsp_implementations<CR>";
        desc = "Show LSP implementations";
      }
      {
        mode = "n";
        key = "gt";
        action = "<cmd>FzfLua lsp_typedefs<CR>";
        desc = "Show LSP type definitions";
      }
      {
        mode = [
          "n"
          "v"
        ];
        key = "<leader>ca";
        action = "vim.lsp.buf.code_action";
        lua = true;
        desc = "See available code actions";
      }
      {
        mode = "n";
        key = "<leader>rn";
        action = "vim.lsp.buf.rename";
        lua = true;
        desc = "Smart rename";
      }
      {
        mode = "n";
        key = "<leader>fd";
        action = "<cmd>FzfLua diagnostics_document<CR>";
        desc = "Show buffer diagnostics";
      }
      {
        mode = "n";
        key = "<leader>d";
        action = "vim.diagnostic.open_float";
        lua = true;
        desc = "Show line diagnostics";
      }
      {
        mode = "n";
        key = "K";
        action = "vim.lsp.buf.hover";
        lua = true;
        desc = "Show documentation for what is under cursor";
      }
      {
        mode = "n";
        key = "<leader>rs";
        action = "<cmd>lsp restart<CR>";
        desc = "Restart LSP";
      }
    ];
  };
}
