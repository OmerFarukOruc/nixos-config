{
  lib,
  osConfig,
  pkgs,
  sessions,
  ...
}:
let
  inherit (import ../../../nixosModules/contrast.nix { inherit lib; }) mixHex legibleOn;

  themeCss =
    { scheme, theme }:
    let
      onCode = legibleOn scheme [ scheme.base01 ];
    in
    ''
      :root {
        --bg: #${scheme.base00};
        --bg-secondary: #${scheme.base01};
        --bg-code: #${scheme.base01};
        --border: #${scheme.base02};
        --border-hover: #${scheme.base03};
        --fg: #${scheme.base05};
        --fg-muted: #${mixHex 80 scheme.base05 scheme.base00};
        --fg-faint: #${scheme.base03};
        --red: #${scheme.base08};
        --orange: #${scheme.base09};
        --yellow: #${scheme.base0A};
        --green: #${scheme.base0B};
        --blue: #${scheme.base0D};
        --cyan: #${scheme.base0C};
        --purple: #${scheme.base0E};
        --code-muted: #${onCode (mixHex 80 scheme.base05 scheme.base00)};
        --code-red: #${onCode scheme.base08};
        --code-orange: #${onCode scheme.base09};
        --code-yellow: #${onCode scheme.base0A};
        --code-green: #${onCode scheme.base0B};
        --code-blue: #${onCode scheme.base0D};
        --code-purple: #${onCode scheme.base0E};
        --select: #${scheme.base02};
        color-scheme: ${theme.polarity};
      }
    '';

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
  config = lib.mkIf (sessions.hasAnyDesktop osConfig.oruc.machine) {
    home.packages = [ viewer ];

    oruc.themeFiles.".config/oruc/pandoc-md-theme.css" = themeCss;

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
  };
}
