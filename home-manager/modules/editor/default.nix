{ inputs, ... }:
{
  imports = [
    inputs.nvf.homeManagerModules.default
    ./core.nix
    ./lsp.nix
    ./plugins.nix
  ];

  programs.nvf = {
    enable = true;
    defaultEditor = true;
    settings.vim = {
      viAlias = true;
      vimAlias = true;
    };
  };
}
