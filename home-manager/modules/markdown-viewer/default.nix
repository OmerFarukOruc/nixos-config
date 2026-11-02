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

  katex = "${pkgs.katex}/lib/node_modules/katex/dist";

  # Version 11.17.2 is the release whose theme variable names pandoc-md.js
  # uses. A new release gets a new URL and a new integrity value, so a rename
  # cannot reach the viewer unchecked. The integrity value is the SHA-384 of
  # mermaid.min.js at that version.
  mermaid = {
    url = "https://cdn.jsdelivr.net/npm/mermaid@11.17.2/dist/mermaid.min.js";
    integrity = "sha384-EOXBFmc3gx5mb+vn0vPvvGqACToJD24hhacX5Yx+8NUUQrHIle/Qi5Bg9o3zKwW2";
  };

  csp =
    hash:
    lib.concatStringsSep "; " [
      "default-src 'none'"
      "script-src 'sha256-${hash}' ${mermaid.url}"
      "style-src file: 'unsafe-inline'"
      "img-src file: data: https:"
      "font-src file:"
      "base-uri file:"
      "form-action 'none'"
    ];

  page = pkgs.runCommand "pandoc-md-page" { } ''
    mkdir "$out"
    substitute ${./pandoc-md.js} viewer.js \
      --replace-fail @mermaidUrl@ ${mermaid.url} \
      --replace-fail @mermaidIntegrity@ ${mermaid.integrity}
    { cat ${katex}/katex.min.js; echo; cat viewer.js; } >script.js
    { printf '<script>'; cat script.js; printf '</script>\n'; } >"$out/afterbody.html"
    hash=$(cksum -a sha256 --base64 --untagged script.js | cut -d' ' -f1)
    printf '<meta http-equiv="Content-Security-Policy" content="%s">\n' \
      "${csp "$hash"}" >"$out/csp.html"
  '';

  viewer = pkgs.writeShellApplication {
    name = "pandoc-md-viewer";
    runtimeInputs = with pkgs; [
      coreutils
      findutils
      gawk
      gnugrep
      jq
      libnotify
      pandoc
    ];
    runtimeEnv = {
      PANDOC_MD_ASSETS = ./assets;
      PANDOC_MD_KATEX = katex;
      PANDOC_MD_PAGE = page;
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
