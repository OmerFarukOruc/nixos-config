{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (config) scheme;

  # The viewer reads this file when it renders, so `theme` can change the
  # colors without a new package.
  themeCss = ''
    :root {
      --bg: #${scheme.base00};
      --bg-secondary: #${scheme.base01};
      --bg-code: #${scheme.base01};
      --border: #${scheme.base02};
      --border-hover: #${scheme.base03};
      --fg: #${scheme.base05};
      --fg-muted: #${scheme.base04};
      --fg-faint: #${scheme.base03};
      --red: #${scheme.base08};
      --orange: #${scheme.base09};
      --yellow: #${scheme.base0A};
      --green: #${scheme.base0B};
      --blue: #${scheme.base0D};
      --purple: #${scheme.base0E};
      --select: #${scheme.base02};
      color-scheme: ${if config.oruc.theme.isLight then "light" else "dark"};
    }
  '';

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
    ];
    runtimeEnv = {
      PANDOC_MD_ASSETS = ./assets;
      PANDOC_MD_KATEX = "${pkgs.katex}/lib/node_modules/katex/dist/";
    };
    text = builtins.readFile ./pandoc-md-viewer.sh;
  };
  mimeTypes = [
    "text/markdown"
    "text/x-markdown"
  ];
in
{
  home.packages = [ viewer ];

  xdg.configFile."oruc/pandoc-md-theme.css".text = themeCss;

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
