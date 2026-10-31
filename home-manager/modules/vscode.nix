{
  config,
  inputs,
  lib,
  osConfig,
  pkgs,
  sessions,
  ...
}:
let
  vibrancy = inputs.vscode-vibrancy;
  appOut = "resources/app/out";
  runtimeDir = "vscode-vibrancy-runtime-v6";
  workbench = "vs/code/electron-browser/workbench/workbench.html";

  vibrancyThemes = lib.genAttrs [ "Default Dark" "Default Light" ] (name: {
    theme = lib.importJSON (vibrancy + "/themes/${name}.json");
    css = builtins.readFile (vibrancy + "/themes/${name}.css");
  });
  vibrancyVersion = (lib.importJSON "${vibrancy}/package.json").version;

  vibrancyFor =
    { scheme, theme }:
    rec {
      themeName = if theme.isLight then "Default Light" else "Default Dark";
      vibrancyTheme = vibrancyThemes.${themeName}.theme;

      rgbOf =
        slot: alpha:
        "rgba(${
          lib.concatStringsSep ", " [
            scheme."${slot}-rgb-r"
            scheme."${slot}-rgb-g"
            scheme."${slot}-rgb-b"
          ]
        }, ${alpha})";
      themeColors = {
        "Default Dark" = {
          "rgba(37, 37, 37,0.3)" = rgbOf "base01" "0.3"; # theme-drift-ok: the upstream literal it replaces
          "rgb(37, 37, 37,0.6)" = rgbOf "base01" "0.6"; # theme-drift-ok: the upstream literal it replaces
          "rgba(41, 41, 41,0.2)" = rgbOf "base02" "0.2"; # theme-drift-ok: the upstream literal it replaces
          "rgba(58, 61, 65,0.6)" = rgbOf "base02" "0.6"; # theme-drift-ok: the upstream literal it replaces
          "rgba(38, 79, 120,0.6)" = rgbOf "base02" "0.6"; # theme-drift-ok: the upstream literal it replaces
          "rgba(37, 37, 38, 0.3)" = rgbOf "base01" "0.3"; # theme-drift-ok: the upstream literal it replaces
          "color: white" = "color: #${scheme.base05}";
        };
        "Default Light" = {
          "rgba(228, 230, 241,0.3)" = rgbOf "base01" "0.3"; # theme-drift-ok: the upstream literal it replaces
          "rgba(228, 230, 241,0.6)" = rgbOf "base01" "0.6"; # theme-drift-ok: the upstream literal it replaces
          "rgb(228, 230, 241,0.6)" = rgbOf "base01" "0.6"; # theme-drift-ok: the upstream literal it replaces
          "rgba(228, 230, 241,0.2)" = rgbOf "base01" "0.2"; # theme-drift-ok: the upstream literal it replaces
          "rgba(228, 230, 241, 0.3)" = rgbOf "base01" "0.3"; # theme-drift-ok: the upstream literal it replaces
          "hsla(210, 100%, 80%, 0.4)" = rgbOf "base02" "0.4"; # theme-drift-ok: the upstream literal it replaces
          "hsla(210, 100%, 80%, 0.6)" = rgbOf "base02" "0.6"; # theme-drift-ok: the upstream literal it replaces
          "hsla(210, 100%, 80%, 0.3)" = rgbOf "base02" "0.3"; # theme-drift-ok: the upstream literal it replaces
          "#616161" = "#${scheme.base04}"; # theme-drift-ok: the upstream literal it replaces
          "#000 " = "#${scheme.base05} ";
          "color: white" = "color: #${scheme.base05}";
        };
      };
      themeCSS =
        let
          colors = themeColors.${themeName};
          inherit (vibrancyThemes.${themeName}) css;
          missing = lib.filter (literal: !lib.hasInfix literal css) (lib.attrNames colors);
        in
        assert lib.assertMsg (
          missing == [ ]
        ) "vscode-vibrancy's ${themeName}.css no longer holds ${builtins.toJSON missing}.";
        builtins.replaceStrings (lib.attrNames colors) (lib.attrValues colors) css;

      injectData = {
        inherit vibrancyVersion;
        os = "linux";
        win11 = false;
        macWindowButtons = false;
        diagnosticsPath = null;
        config = {
          type = "auto";
          opacity = -1;
          backgroundOverride = "#${scheme.base00}";
          theme = themeName;
          enableAutoTheme = false;
          preferredDarkTheme = "Default Dark";
          preferredLightTheme = "Default Light";
          preferedDarkTheme = "Default Dark";
          preferedLightTheme = "Default Light";
          imports = [ "/path/to/file" ];
          refreshInterval = 10;
          preventFlash = true;
          windowMode = "auto";
          windowControlsStyle = "auto";
          forceFramelessWindow = false;
          disableFramelessWindow = false;
          disableThemeFixes = false;
          disableColorCustomizations = false;
        };
        theme = vibrancyTheme;
        inherit themeCSS;
        imports = {
          css = "";
          js = "";
        };
      };

      alpha =
        opacity:
        lib.toLower (lib.fixedWidthString 2 "0" (lib.toHexString (builtins.floor (opacity * 255 + 0.5))));
      baseColors = {
        "sideBar.background" = scheme.base01;
      };
      colorsWith =
        suffix: keys: lib.genAttrs keys (key: "#${baseColors.${key} or scheme.base00}${suffix}");
      colorCustomizations =
        colorsWith "00" [
          "editorPane.background"
          "editorGroupHeader.tabsBackground"
          "editorGroupHeader.noTabsBackground"
          "breadcrumb.background"
          "editorGutter.background"
          "panel.background"
          "tab.activeBackground"
          "tab.unfocusedActiveBackground"
        ]
        // colorsWith (alpha vibrancyTheme.opacity.linux) [
          "sideBar.background"
          "sideBarTitle.background"
          "activityBar.background"
          "editor.background"
          "tab.inactiveBackground"
          "tab.unfocusedInactiveBackground"
        ]
        // colorsWith (alpha (lib.max vibrancyTheme.opacity.linux 0.75)) [
          "editorStickyScroll.background"
          "editorStickyScrollGutter.background"
          "sideBarStickyScroll.background"
          "panelStickyScroll.background"
          "terminalStickyScroll.background"
          "minimap.background"
        ]
        // colorsWith (alpha 0.9) [
          "inlineChat.background"
          "editorWidget.background"
          "editorHoverWidget.background"
          "editorSuggestWidget.background"
          "notifications.background"
          "notificationCenterHeader.background"
          "menu.background"
          "quickInput.background"
        ]
        // vibrancyTheme.colorCustomizations
        // {
          "terminal.background" = "#00000000";
        };
    };

  themeFile = ".config/oruc/vscode-theme.json";
  colorsFile = ".config/oruc/vscode-colors.json";
  vibrancyFile = ".config/oruc/vscode-vibrancy.json";
  themeLabel = polarity: "Oruc Base16 ${lib.toSentenceCase polarity}";

  extension = pkgs.vscode-utils.buildVscodeExtension {
    pname = "oruc-base16-theme";
    version = "2.0.0";
    vscodeExtPublisher = "oruc";
    vscodeExtName = "base16-theme";
    vscodeExtUniqueId = "oruc.base16-theme";
    dontUnpack = true;
    installPhase = ''
      mkdir -p "$out/$installPrefix/themes"
      cp ${
        pkgs.writeText "package.json" (
          builtins.toJSON {
            name = "base16-theme";
            publisher = "oruc";
            version = "2.0.0";
            engines.vscode = "^1.85.0";
            contributes.themes =
              map
                (polarity: {
                  label = themeLabel polarity;
                  uiTheme = if polarity == "light" then "vs" else "vs-dark";
                  path = "./themes/oruc.json";
                  _watch = true;
                })
                [
                  "dark"
                  "light"
                ];
          }
        )
      } "$out/$installPrefix/package.json"
      ln -s ${lib.escapeShellArg "${config.home.homeDirectory}/${themeFile}"} "$out/$installPrefix/themes/oruc.json"
    '';
  };

  contrast = import ../../nixosModules/contrast.nix { inherit lib; };
  warmBurnout = import ./warm-burnout.nix { inherit inputs pkgs; };

  template = builtins.readFile "${inputs.tinted-vscode}/templates/base16.mustache";
  accents = map (n: "base0${n}") (lib.stringToCharacters "89ABCDEF");
  entryOf =
    line:
    let
      found = builtins.match ''[[:space:]]*"([^"]+)": "#[{][{](base0[0-9A-F])-hex[}][}]([0-9a-fA-F]*)".*'' line;
    in
    if found == null then
      null
    else
      {
        key = builtins.elemAt found 0;
        slot = builtins.elemAt found 1;
        alpha = builtins.elemAt found 2;
      };
  templateLines = map (line: {
    inherit line;
    entry = entryOf line;
  }) (lib.splitString "\n" template);
  entries = lib.listToAttrs (
    map (line: lib.nameValuePair line.entry.key line.entry) (
      lib.filter (line: line.entry != null) templateLines
    )
  );
  backgroundOf =
    entry:
    let
      parts = builtins.match "(.*)([fF])oreground" entry.key;
      key =
        builtins.elemAt parts 0 + (if builtins.elemAt parts 1 == "F" then "Background" else "background");
      background = entries.${key} or null;
    in
    if
      entry.alpha == ""
      && parts != null
      && background != null
      && background.alpha == ""
      && lib.elem background.slot accents
    then
      background
    else
      null;
  readablePairs = lib.filter (pair: pair.background != null) (
    lib.mapAttrsToList (_: entry: entry // { background = backgroundOf entry; }) entries
  );
  hovers = {
    "button.hoverBackground" = "button.foreground";
    "button.secondaryHoverBackground" = "button.secondaryForeground";
    "extensionButton.prominentHoverBackground" = "extensionButton.prominentForeground";
    "notification.buttonHoverBackground" = "notification.buttonForeground";
    "statusBarItem.hoverBackground" = "statusBar.foreground";
    "statusBarItem.prominentHoverBackground" = "statusBarItem.prominentForeground";
  };
  roles = {
    base02 = "faint";
    base03 = "faint";
    base04 = "dim";
    base05 = "foreground";
  };
  decorations = [
    "editorWhitespace.foreground"
    "editorRuler.foreground"
    "editorGutter.commentRangeForeground"
  ];
  roleOf =
    entry:
    if
      entry.alpha == ""
      && roles ? ${entry.slot}
      && builtins.match ".*[fF]oreground" entry.key != null
      && !lib.elem entry.key decorations
    then
      roles.${entry.slot}
    else
      null;
  readableSlot = lib.listToAttrs (
    map (pair: lib.nameValuePair pair.key pair.background.slot) readablePairs
  );
  textKeys = lib.filter (
    key:
    key != "foreground" && roleOf entries.${key} != null && !readableSlot ? ${key} && !hovers ? ${key}
  ) (lib.attrNames entries);
  tagOf =
    entry:
    if entry == null || entry.alpha != "" then
      null
    else if readableSlot ? ${entry.key} then
      "{{oruc-on-${readableSlot.${entry.key}}}}"
    else if hovers ? ${entry.key} then
      "{{oruc-hover-${readableSlot.${hovers.${entry.key}}}}}"
    else if roleOf entry != null then
      "{{oruc-${roleOf entry}}}"
    else
      null;
  taggedTemplate = lib.concatMapStringsSep "\n" (
    { line, entry }:
    let
      tag = tagOf entry;
    in
    if tag == null then line else builtins.replaceStrings [ "{{${entry.slot}-hex}}" ] [ tag ] line
  ) templateLines;
  slots = map (n: "base0${n}") (lib.stringToCharacters "0123456789ABCDEF");
  renderTheme =
    { scheme, theme }:
    let
      on = lib.genAttrs accents (slot: theme.readableOn scheme.${slot});
      text = contrast.textRoles scheme [
        scheme.base00
        scheme.base01
      ];
      tags =
        lib.mapAttrs' (slot: color: lib.nameValuePair "oruc-on-${slot}" color) on
        // lib.mapAttrs' (
          slot: color: lib.nameValuePair "oruc-hover-${slot}" (contrast.hoverOf scheme.${slot} color)
        ) on
        // lib.mapAttrs' (role: color: lib.nameValuePair "oruc-${role}" color) text
        // lib.genAttrs (map (slot: "${slot}-hex") slots) (tag: scheme.${lib.removeSuffix "-hex" tag})
        // {
          scheme-name = lib.removePrefix "\"" (lib.removeSuffix "\"" (builtins.toJSON scheme.scheme-name));
          scheme-variant = theme.polarity;
        };
    in
    builtins.replaceStrings (map (tag: "{{${tag}}}") (
      lib.attrNames tags
    )) (lib.attrValues tags) taggedTemplate;
  pairsFact = _: lib.concatMapStrings (pair: "${pair.key} ${pair.background.key}\n") readablePairs;
  textFact = _: lib.concatMapStrings (key: "${key} ${roleOf entries.${key}}\n") textKeys;
  labelOf =
    theme:
    if theme.warmBurnout then
      "Warm Burnout ${lib.toSentenceCase theme.polarity}"
    else
      themeLabel theme.polarity;

  renderColors =
    { scheme, theme }:
    let
      hashed = scheme.withHashtag;
      ansi = lib.listToAttrs (
        lib.imap0 (
          index: slot:
          let
            row = if index < 8 then "" else "Bright";
            color = builtins.elemAt theme.ansiNames (lib.mod index 8);
          in
          lib.nameValuePair "terminal.ansi${row}${color}" hashed.${slot}
        ) theme.ansi
      );
      look = vibrancyFor { inherit scheme theme; };
    in
    builtins.toJSON {
      "workbench.colorTheme" = labelOf theme;
      "window.systemColorTheme" = look.vibrancyTheme.systemColorTheme;
      "workbench.colorCustomizations" =
        look.colorCustomizations // { "terminal.foreground" = hashed.base05; } // ansi;
    };

  mutableSettings =
    name:
    import "${inputs.home-manager}/modules/programs/vscode/mutableSettings.nix" {
      inherit lib pkgs name;
    };
  codeColors = pkgs.writeShellApplication {
    name = "oruc-code-colors";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.diffutils
    ];
    text = ''
      errorEcho() { echo "oruc-code-colors: $*" >&2; }
      verboseEcho() { :; }
      run() { "$@"; }
      ${mutableSettings "editor"}
      vscodeMutableSettings "$1" "$2"
    '';
  };

  injectFile = "${config.xdg.configHome}/oruc/vscode-vibrancy.json";
  bootstrapJs = pkgs.writeText "vscode-vibrancy-bootstrap.js" ''

    /* !! VSCODE-VIBRANCY-START !! */
    ;(function(){
    try{ global.vscode_vibrancy_plugin = JSON.parse(process.getBuiltinModule("node:fs").readFileSync(${builtins.toJSON injectFile}, "utf8")); import("@vibrancyRuntimeUrl@"); } catch (err) {console.error(err)}
    })()
    /* !! VSCODE-VIBRANCY-END !! */
  '';

  vscode = pkgs.vscode.overrideAttrs (old: {
    nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [ pkgs.jq ];
    postPatch = (old.postPatch or "") + ''
      runtimeEntry="$out/lib/vscode/${appOut}/${runtimeDir}/index.cjs"
      # VS Code 1.140 and newer create the window in mainImpl.js.
      windowFile="${appOut}/mainImpl.js"
      [[ -f $windowFile ]] || windowFile="${appOut}/main.js"
      chmod u+w resources/app "${appOut}" "${appOut}/main.js" "$windowFile" \
        "${appOut}/vs/code/electron-browser/workbench" "${appOut}/${workbench}"

      cp -r "${vibrancy}/runtime-pre-esm" "${appOut}/${runtimeDir}"

      sed -i 's/experimentalDarkMode/frame:false,transparent:true,experimentalDarkMode/g' "$windowFile"
      grep -q 'frame:false,transparent:true,experimentalDarkMode' "$windowFile" ||
        { echo "vibrancy: no window options to patch in $windowFile" >&2; exit 1; }

      substitute ${bootstrapJs} vscode-vibrancy-bootstrap.js \
        --replace-fail "@vibrancyRuntimeUrl@" "file://$runtimeEntry"
      cat vscode-vibrancy-bootstrap.js >>"${appOut}/main.js"
      rm vscode-vibrancy-bootstrap.js

      sed -i 's/^[[:space:]]*trusted-types$/& VscodeVibrancyContinued/' "${appOut}/${workbench}"
      grep -q 'trusted-types VscodeVibrancyContinued' "${appOut}/${workbench}" ||
        { echo "vibrancy: no trusted-types line in ${workbench}" >&2; exit 1; }

      # VS Code checks workbench.html against product.json and reports a
      # corrupt installation when they differ.
      checksum=$(sha256sum "${appOut}/${workbench}" | cut -d' ' -f1)
      checksum=$(printf "$(sed 's/../\\x&/g' <<<"$checksum")" | base64 | tr -d '=')
      jq --arg key "${workbench}" --arg value "$checksum" '.checksums[$key] = $value' \
        resources/app/product.json >product.json.new
      grep -q "$checksum" product.json.new ||
        { echo "vibrancy: product.json has no workbench.html checksum" >&2; exit 1; }
      mv product.json.new resources/app/product.json
    '';
  });
  ghosttyFonts = lib.concatMapStringsSep ", " (font: "'${font}'") (
    lib.toList config.programs.ghostty.settings.font-family
  );
  colorKeys = [
    "workbench.colorTheme"
    "window.systemColorTheme"
    "workbench.colorCustomizations"
  ];
  settingsPath = "${config.xdg.configHome}/Code/User/settings.json";
  colorsPath = "${config.home.homeDirectory}/${colorsFile}";
in
{
  options.oruc = {
    vscodeSettings = lib.mkOption {
      inherit (pkgs.formats.json { }) type;
      default = { };
      description = ''
        VS Code settings that each switch writes into settings.json, over the
        values there. Settings Sync skips these keys, so this machine's look
        stays off the other machines.
      '';
    };
  };

  config = lib.mkIf (sessions.hasAnyDesktop osConfig.oruc.machine) {
    oruc.vscodeSettings = {
      "editor.fontFamily" = "${ghosttyFonts}, monospace";
      "extensions.autoCheckUpdates" = false;
      "extensions.autoUpdate" = false;
      "remote.SSH.defaultExtensions" = [ "mhutchie.git-graph" ];
      "security.workspace.trust.enabled" = false;
      "telemetry.telemetryLevel" = "off";
      "terminal.integrated.fontFamily" = ghosttyFonts;
      "terminal.integrated.gpuAcceleration" = "off";
      "window.autoDetectColorScheme" = false;
      "window.controlsStyle" = "custom";
      "window.dialogStyle" = "custom";
      "update.mode" = "none";
      "workbench.editorAssociations"."*.md" = "vscode.markdown.preview.editor";
    };

    programs.vscode = {
      enable = true;
      package = vscode;
      mutableExtensionsDir = true;
      profiles.default = {
        extensions = [
          extension
          warmBurnout.vscode
        ];
        # Settings Sync and the settings editor write settings.json, so it
        # must be a writable file instead of a link into the store.
        mutableUserSettings = true;
        userSettings = config.oruc.vscodeSettings // {
          "settingsSync.ignoredSettings" = lib.attrNames config.oruc.vscodeSettings ++ colorKeys;
        };
      };
    };

    home.activation.vscodeMutableUserSettings = lib.mkForce (
      lib.hm.dag.entryAfter [ "linkGeneration" ] ''
        ${mutableSettings "Visual Studio Code"}
        vscodeMutableSettings ${lib.escapeShellArg settingsPath} \
          ${
            (pkgs.formats.json { }).generate "vscode-user-settings"
              config.programs.vscode.profiles.default.userSettings
          } ||
          warnEcho "VS Code settings.json is unchanged, so the declared settings apply at the next switch after it parses."
      ''
    );

    home.activation.vscodeColors =
      lib.hm.dag.entryAfter
        [
          "vscodeMutableUserSettings"
          "orucThemePointer"
        ]
        ''
          run ${lib.getExe codeColors} ${lib.escapeShellArg settingsPath} ${lib.escapeShellArg colorsPath} ||
            warnEcho "VS Code settings.json is unchanged, so the scheme's colours apply at the next switch after it parses."
        '';

    oruc.themeFiles = {
      ${themeFile} = renderTheme;
      ${colorsFile} = renderColors;
      ${vibrancyFile} = args: builtins.toJSON (vibrancyFor args).injectData;
    };
    oruc.themeCopies = [ themeFile ];
    oruc.themeFacts = {
      vscode-pairs = pairsFact;
      vscode-text = textFact;
      vscode-label = { theme, ... }: "${labelOf theme}\n";
    };

    oruc.variantReloads.vscode = ''
      ${lib.getExe codeColors} ${lib.escapeShellArg settingsPath} ${lib.escapeShellArg colorsPath}
    '';

    assertions =
      let
        profile = config.programs.vscode.profiles.default;
      in
      [
        {
          assertion =
            lib.attrNames profile.userSettings
            == lib.attrNames (config.oruc.vscodeSettings // { "settingsSync.ignoredSettings" = null; })
            && profile.enableUpdateCheck == null
            && profile.enableExtensionUpdateCheck == null;
          message = "Set VS Code settings through oruc.vscodeSettings, so Settings Sync skips them.";
        }
      ];
  };
}
