{
  config,
  lib,
  osConfig,
  pkgs,
  sessions,
  ...
}:
let
  inherit (config) scheme;

  # `pct` percent of color `a` over color `b`, both six hex digits. Integer math
  # keeps the result a plain hex value, which Mermaid can parse.
  mixHex =
    pct: a: b:
    let
      channel =
        i:
        let
          part = c: lib.fromHexString (builtins.substring (2 * i) 2 c);
          value = (part a * pct + part b * (100 - pct) + 50) / 100;
        in
        lib.optionalString (value < 16) "0" + lib.toHexString value;
    in
    lib.concatMapStrings channel [
      0
      1
      2
    ];

  # WCAG 2.x contrast ratio of two colors, each six hex digits. Nix has no
  # power function, so x^2.4 is x^2 times the square of the fifth root of x,
  # which Newton's method finds.
  contrast =
    a: b:
    let
      fifthRoot =
        x: builtins.foldl' (y: _: y - (y * y * y * y * y - x) / (5.0 * y * y * y * y)) 1.0 (lib.range 1 40);
      linear =
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
          u * u * r * r;
      luminance =
        c:
        let
          part = i: linear (lib.fromHexString (builtins.substring (2 * i) 2 c));
        in
        0.2126 * part 0 + 0.7152 * part 1 + 0.0722 * part 2;
      la = luminance a;
      lb = luminance b;
    in
    (lib.max la lb + 0.05) / (lib.min la lb + 0.05);

  # `color` moved toward the text color by the fewest whole percent that gives
  # it a 4.5:1 contrast on the code background. A color that already reads
  # keeps its value, and one that needs help keeps close to its hue.
  onCode =
    color:
    let
      moved = pct: mixHex (100 - pct) color scheme.base05;
      pct = lib.findFirst (p: contrast (moved p) scheme.base01 >= 4.5) null (lib.range 0 100);
    in
    if pct == null then
      throw "markdown-viewer: ${color} cannot reach 4.5:1 on the code background"
    else
      moved pct;

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
  # The viewer opens a browser, so only a machine with a desktop session gets it.
  config = lib.mkIf (sessions.hasAnyDesktop osConfig.oruc.machine) {
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
  };
}
