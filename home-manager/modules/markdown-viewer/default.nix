{ lib, pkgs, ... }:
let
  # The script carries its own pandoc, so no host needs it in its package list.
  viewer = pkgs.writeShellApplication {
    name = "pandoc-md-viewer";
    runtimeInputs = with pkgs; [
      coreutils
      findutils
      gawk
      gnugrep
      libnotify
      pandoc
      xdg-utils
    ];
    runtimeEnv.PANDOC_MD_ASSETS = ./assets;
    text = builtins.readFile ./pandoc-md-viewer.sh;
  };
  mimeTypes = [
    "text/markdown"
    "text/x-markdown"
  ];
in
{
  home.packages = [ viewer ];

  xdg.desktopEntries.pandoc-md-viewer = {
    name = "Markdown Viewer (Pandoc)";
    comment = "Render Markdown files as styled HTML in the browser";
    exec = "${lib.getExe viewer} %f";
    mimeType = mimeTypes;
    terminal = false;
    noDisplay = true;
    categories = [
      "Utility"
      "Viewer"
    ];
  };

  xdg.mimeApps.defaultApplications = lib.genAttrs mimeTypes (_: [ "pandoc-md-viewer.desktop" ]);

  # Oh My Zsh aliases md to mkdir -p; the shell already aliases mkdir to mkdir -pv.
  programs.zsh.shellAliases.md = "pandoc-md-viewer";
}
