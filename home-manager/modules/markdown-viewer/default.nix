{
  lib,
  osConfig,
  pkgs,
  sessions,
  ...
}:
let
  channels =
    color:
    map (i: lib.fromHexString (builtins.substring (2 * i) 2 color)) [
      0
      1
      2
    ];
  mix = pct: lib.zipListsWith (a: b: (a * pct + b * (100 - pct) + 50) / 100);
  mixHex =
    pct: a: b:
    lib.concatMapStrings (value: lib.optionalString (value < 16) "0" + lib.toHexString value) (
      mix pct (channels a) (channels b)
    );

  linear =
    let
      fifthRoot =
        x: builtins.foldl' (y: _: y - (y * y * y * y * y - x) / (5.0 * y * y * y * y)) 1.0 (lib.range 1 40);
    in
    lib.genList (
      value:
      let
        v = value / 255.0;
      in
      if v <= 0.03928 then
        v / 12.92
      else
        let
          u = (v + 0.055) / 1.055;
          r = fifthRoot u;
        in
        u * u * r * r
    ) 256;

  luminance =
    rgb:
    let
      part = i: builtins.elemAt linear (builtins.elemAt rgb i);
    in
    0.2126 * part 0 + 0.7152 * part 1 + 0.0722 * part 2;
  contrast = la: lb: (lib.max la lb + 0.05) / (lib.min la lb + 0.05);

  themeCss =
    { scheme, theme }:
    let
      code = luminance (channels scheme.base01);
      reaching =
        color: target:
        let
          from = channels color;
          to = channels target;
        in
        lib.findFirst (pct: contrast (luminance (mix (100 - pct) from to)) code >= 4.5) null (
          lib.range 0 100
        );
      contrastOn = color: contrast (luminance (channels color)) code;
      extreme = if contrastOn "000000" > contrastOn "ffffff" then "000000" else "ffffff";
      onCode =
        color:
        let
          towardFg = reaching color scheme.base05;
        in
        if towardFg != null then
          mixHex (100 - towardFg) color scheme.base05
        else
          mixHex (100 - reaching color extreme) color extreme;
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
