{
  programs.nvf.settings.vim = {
    globals = {
      mapleader = " ";
      netrw_liststyle = 3;
    };

    lineNumberMode = "relative";

    options = {
      sessionoptions = "blank,buffers,curdir,folds,help,tabpages,winsize,winpos,terminal,localoptions";
      tabstop = 4;
      shiftwidth = 4;
      expandtab = true;
      autoindent = true;
      wrap = false;
      ignorecase = true;
      smartcase = true;
      cursorline = true;
      termguicolors = true;
      signcolumn = "yes";
      backspace = "indent,eol,start";
      splitright = true;
      splitbelow = true;
    };

    keymaps = [
      {
        mode = "i";
        key = "jk";
        action = "<ESC>";
        desc = "Exit insert mode with jk";
      }
      {
        mode = "n";
        key = "<leader>nh";
        action = ":nohl<CR>";
        desc = "Clear search highlights";
      }

      {
        mode = "n";
        key = "<leader>sv";
        action = "<C-w>v";
        desc = "Split window vertically";
      }
      {
        mode = "n";
        key = "<leader>sh";
        action = "<C-w>s";
        desc = "Split window horizontally";
      }
      {
        mode = "n";
        key = "<leader>se";
        action = "<C-w>=";
        desc = "Make splits equal size";
      }
      {
        mode = "n";
        key = "<leader>sx";
        action = "<cmd>close<CR>";
        desc = "Close current split";
      }

      {
        mode = "n";
        key = "<leader>to";
        action = "<cmd>tabnew<CR>";
        desc = "Open new tab";
      }
      {
        mode = "n";
        key = "<leader>tx";
        action = "<cmd>tabclose<CR>";
        desc = "Close current tab";
      }
      {
        mode = "n";
        key = "<leader>tn";
        action = "<cmd>tabn<CR>";
        desc = "Go to next tab";
      }
      {
        mode = "n";
        key = "<leader>tp";
        action = "<cmd>tabp<CR>";
        desc = "Go to previous tab";
      }
      {
        mode = "n";
        key = "<leader>tf";
        action = "<cmd>tabnew %<CR>";
        desc = "Open current buffer in new tab";
      }

      {
        mode = "n";
        key = "<leader>ww";
        action = "<cmd>w<CR>";
        desc = "Write the buffer";
      }
      {
        mode = "n";
        key = "<leader>wa";
        action = "<cmd>wa<CR>";
        desc = "Write all changed buffers";
      }
      {
        mode = "n";
        key = "<leader>wq";
        action = "<cmd>wqa<CR>";
        desc = "Write all changed buffers and exit";
      }
      {
        mode = "n";
        key = "<leader>qq";
        action = "<cmd>q<CR>";
        desc = "Quit the current window";
      }
      {
        mode = "n";
        key = "<leader>qi";
        action = "<cmd>qa<CR>";
        desc = "Exit unless a buffer has changes";
      }
      {
        mode = "n";
        key = "<leader>qa";
        action = "<cmd>qa!<CR>";
        desc = "Exit and discard all changes";
      }
    ];
  };
}
