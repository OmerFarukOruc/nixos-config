# VS Code with a transparent, frameless window, which the compositor blurs.
# The steps mirror what the vscode-vibrancy-continued extension does to an
# installed VS Code, done at build time because the store is read-only. Each
# edit fails the build when VS Code no longer has the text it changes.
{
  config,
  inputs,
  lib,
  pkgs,
  ...
}:
let
  vibrancy = inputs.vscode-vibrancy;
  appOut = "resources/app/out";
  runtimeDir = "vscode-vibrancy-runtime-v6";
  workbench = "vs/code/electron-browser/workbench/workbench.html";

  inherit (config) scheme;
  themeName = if config.oruc.theme.isLight then "Default Light" else "Default Dark";
  theme = builtins.fromJSON (builtins.readFile (vibrancy + "/themes/${themeName}.json"));

  # The fixed colors in the extension's stylesheet for each theme, each with
  # the scheme color that replaces it at the same alpha. An evaluation fails
  # when the input no longer holds one of them, so a new release cannot keep
  # a grey unnoticed.
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
      "rgba(37, 37, 37,0.3)" = rgbOf "base01" "0.3";
      "rgb(37, 37, 37,0.6)" = rgbOf "base01" "0.6";
      "rgba(41, 41, 41,0.2)" = rgbOf "base02" "0.2";
      "rgba(58, 61, 65,0.6)" = rgbOf "base02" "0.6";
      "rgba(38, 79, 120,0.6)" = rgbOf "base02" "0.6";
      "rgba(37, 37, 38, 0.3)" = rgbOf "base01" "0.3";
      "color: white" = "color: #${scheme.base05}";
    };
    "Default Light" = {
      "rgba(228, 230, 241,0.3)" = rgbOf "base01" "0.3";
      "rgba(228, 230, 241,0.6)" = rgbOf "base01" "0.6";
      "rgb(228, 230, 241,0.6)" = rgbOf "base01" "0.6";
      "rgba(228, 230, 241,0.2)" = rgbOf "base01" "0.2";
      "rgba(228, 230, 241, 0.3)" = rgbOf "base01" "0.3";
      "hsla(210, 100%, 80%, 0.4)" = rgbOf "base02" "0.4";
      "hsla(210, 100%, 80%, 0.6)" = rgbOf "base02" "0.6";
      "hsla(210, 100%, 80%, 0.3)" = rgbOf "base02" "0.3";
      "#616161" = "#${scheme.base04}";
      "#000 " = "#${scheme.base05} ";
      "color: white" = "color: #${scheme.base05}";
    };
  };
  themeCSS =
    let
      colors = themeColors.${themeName};
      css = builtins.readFile (vibrancy + "/themes/${themeName}.css");
      missing = lib.filter (literal: !lib.hasInfix literal css) (lib.attrNames colors);
    in
    assert lib.assertMsg (
      missing == [ ]
    ) "vscode-vibrancy's ${themeName}.css no longer holds ${builtins.toJSON missing}.";
    builtins.replaceStrings (lib.attrNames colors) (lib.attrValues colors) css;

  # The extension's global.vscode_vibrancy_plugin on Linux, in the shape that
  # buildMainJS in v1.4.0's extension/index.js builds; a new release can
  # change that shape. The settings are the defaults, except that the
  # theme follows the scheme's variant and the background is the scheme's
  # base00.
  injectData = {
    vibrancyVersion = (lib.importJSON "${vibrancy}/package.json").version;
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
    inherit theme;
    inherit themeCSS;
    imports = {
      css = "";
      js = "";
    };
  };

  # VS Code reads the settings from a file at start, because they follow the
  # scheme and `theme` switches the scheme without a new VS Code package
  # (home-manager/modules/variants.nix).
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

      # A frameless, transparent window.
      sed -i 's/experimentalDarkMode/frame:false,transparent:true,experimentalDarkMode/g' "$windowFile"
      grep -q 'frame:false,transparent:true,experimentalDarkMode' "$windowFile" ||
        { echo "vibrancy: no window options to patch in $windowFile" >&2; exit 1; }

      substitute ${bootstrapJs} vscode-vibrancy-bootstrap.js \
        --replace-fail "@vibrancyRuntimeUrl@" "file://$runtimeEntry"
      cat vscode-vibrancy-bootstrap.js >>"${appOut}/main.js"
      rm vscode-vibrancy-bootstrap.js

      # Allow the runtime's Trusted Types policy.
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
  # The settings the extension's applySettings writes: see-through
  # backgrounds from its key lists in extension/file-transforms.js, with an
  # opacity of -1 meaning the theme's Linux opacity. A key keeps the colour
  # it would have without vibrancy and gets only a new alpha.
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
    // colorsWith (alpha theme.opacity.linux) [
      "sideBar.background"
      "sideBarTitle.background"
      "activityBar.background"
      "editor.background"
      "tab.inactiveBackground"
      "tab.unfocusedInactiveBackground"
    ]
    // colorsWith (alpha (lib.max theme.opacity.linux 0.75)) [
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
    // theme.colorCustomizations
    // {
      "terminal.background" = "#00000000";
    };
  ghosttyFonts = lib.concatMapStringsSep ", " (font: "'${font}'") (
    lib.toList config.programs.ghostty.settings.font-family
  );
in
{
  options.oruc.vscodeSettings = lib.mkOption {
    inherit (pkgs.formats.json { }) type;
    default = { };
    description = ''
      VS Code settings that each switch writes into settings.json, over the
      values there. Settings Sync skips these keys, so this machine's look
      stays off the other machines.
    '';
  };

  config = {
    oruc.vscodeSettings = {
      # Ghostty's font, which every host installs. A missing family falls
      # back to a proportional font and breaks the column layout.
      "editor.fontFamily" = "${ghosttyFonts}, monospace";
      "extensions.autoCheckUpdates" = false;
      "extensions.autoUpdate" = false;
      "remote.SSH.defaultExtensions" = [ "mhutchie.git-graph" ];
      # Every folder opens trusted, without the Restricted Mode prompt.
      "security.workspace.trust.enabled" = false;
      "telemetry.telemetryLevel" = "off";
      "terminal.integrated.fontFamily" = ghosttyFonts;
      "terminal.integrated.gpuAcceleration" = "off";
      "window.autoDetectColorScheme" = false;
      "window.controlsStyle" = "custom";
      # Dialogs drawn in the window, where scripts/vscode-cdp-on-rog.sh reaches them.
      "window.dialogStyle" = "custom";
      "window.systemColorTheme" = theme.systemColorTheme;
      "update.mode" = "none";
      "workbench.colorCustomizations" = colorCustomizations;
      "workbench.editorAssociations"."*.md" = "vscode.markdown.preview.editor";
    };

    xdg.configFile."oruc/vscode-vibrancy.json".text = builtins.toJSON injectData;

    programs.vscode = {
      enable = true;
      package = vscode;
      mutableExtensionsDir = true;
      profiles.default = {
        # Settings Sync and the settings editor write settings.json, so it
        # must be a writable file instead of a link into the store.
        mutableUserSettings = true;
        userSettings = config.oruc.vscodeSettings // {
          "settingsSync.ignoredSettings" = lib.attrNames config.oruc.vscodeSettings;
        };
      };
    };

    # Home Manager's own step fails the switch when it cannot merge, such as
    # after a hand edit that is not JSON5, and a deploy then rolls back. This
    # runs the same merge, but a failure only warns and keeps the file.
    home.activation.vscodeMutableUserSettings = lib.mkForce (
      lib.hm.dag.entryAfter [ "linkGeneration" ] ''
        ${import "${inputs.home-manager}/modules/programs/vscode/mutableSettings.nix" {
          inherit lib pkgs;
          name = "Visual Studio Code";
        }}
        vscodeMutableSettings ${lib.escapeShellArg "${config.xdg.configHome}/Code/User/settings.json"} \
          ${
            (pkgs.formats.json { }).generate "vscode-user-settings"
              config.programs.vscode.profiles.default.userSettings
          } \
          || warnEcho "VS Code settings.json is unchanged, so the declared settings apply at the next switch after it parses."
      ''
    );

    # A key set any other way, including through the two update-check
    # options, reaches settings.json without the ignore list, so Settings
    # Sync copies it to the other machines.
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
