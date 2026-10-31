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
  isPlasma = sessions.hasDesktop osConfig.oruc.machine "plasma";
  inherit (config.oruc.theme) wallpaper;

  # Panel Colorizer keeps its whole style in one JSON value, globalSettings,
  # and fills every key left out here from its own defaults. Its typed
  # options in plasma-manager write the setting names of releases before 3,
  # which current releases ignore.
  # The keys are in package/contents/ui/code/globals.js of plasma-panel-colorizer.
  # sourceType 0 is a custom color, 1 a color from the Plasma color scheme.
  colorizer = colorizerWith { };
  colorizerWith = general: style: {
    name = "luisbocanegra.panel.colorizer";
    config.General = general // {
      hideWidget = true;
      globalSettings = builtins.toJSON style;
    };
  };

  # kVitals keeps its settings in profiles. When the panels are built again,
  # it copies its settings into a new first profile as soon as it loads, which
  # can be before plasma-manager has written them all; a key written later
  # stays out of the profile. So the settings are also the package's defaults
  # (contents/config/main.xml), which the copy reads for a key not yet written.
  # Only the keys that differ from kVitals' own defaults are here.
  # kVitals colors its own text, so the top bar's accent color reaches it only
  # through fontColor. Its threshold colors still take precedence.
  # warningColor is base09 and criticalColor base08, as in the other warning
  # and error states.
  kvitalsSettings = {
    pinnedMetrics = "cpu/usage,bat/percentage,cpu/freq,cpu/temp,ram/used,uptime/uptime";
    layoutType = "vertical";
    iconSize = 8;
    fontBold = true;
    updateInterval = 1000;
    enableThresholdColors = true;
    labelOpacity = 0.5;
    separatorOpacity = 1;
    useCustomColors = true;
    fontColor = config.scheme.withHashtag.base0D;
    warningColor = config.scheme.withHashtag.base09;
    criticalColor = config.scheme.withHashtag.base08;
  }
  // lib.optionalAttrs (osConfig.oruc.machine.gpu == "hybrid") {
    gpuSelection = "gpu1";
  };
  kvitals = {
    name = "org.kde.plasma.kvitals";
    config.General = kvitalsSettings;
  };
  kvitalsPackage = (pkgs.callPackage ../../pkgs/kvitals.nix { }).overrideAttrs (old: {
    nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [ pkgs.xmlstarlet ];
    postInstall =
      (old.postInstall or "")
      + ''
        xml=$out/share/plasma/plasmoids/org.kde.plasma.kvitals/contents/config/main.xml
      ''
      + lib.concatStrings (
        lib.mapAttrsToList (
          key: value:
          let
            text = lib.escapeShellArg (
              if builtins.isBool value then lib.boolToString value else toString value
            );
            entry = "//k:entry[@name='${key}']/k:default";
          in
          ''
            xmlstarlet ed -L -N k=http://www.kde.org/standards/kcfg/1.0 -u "${entry}" -v ${text} "$xml"
            [ "$(xmlstarlet sel -N k=http://www.kde.org/standards/kcfg/1.0 -t -v "${entry}" "$xml")" = ${text} ]
          ''
        ) packageDefaults
      );
  });
  packageDefaults = kvitalsSettings // {
    fontColor = osConfig.scheme.withHashtag.base0D;
    warningColor = osConfig.scheme.withHashtag.base09;
    criticalColor = osConfig.scheme.withHashtag.base08;
  };

  allCorners = value: {
    topLeft = value;
    topRight = value;
    bottomLeft = value;
    bottomRight = value;
  };
  schemeColor = systemColor: systemColorSet: alpha: {
    enabled = true;
    sourceType = 1;
    inherit systemColor systemColorSet alpha;
  };
  softShadow = size: {
    enabled = true;
    inherit size;
    xOffset = 0;
    yOffset = 1;
    color = {
      sourceType = 0;
      custom = "#000000";
      alpha = 0.3;
    };
  };
  hiddenNativeBackground.background = {
    opacity = 0;
    shadow = false;
  };

  topBarStyle = {
    nativePanel = hiddenNativeBackground;
    widgets.normal = {
      enabled = true;
      blurBehind = true;
      backgroundColor = schemeColor "backgroundColor" "Window" 0.5;
      foregroundColor = schemeColor "highlightColor" "Window" 1;
      radius = {
        enabled = true;
        corner = allCorners 3;
      };
      border = {
        enabled = true;
        width = 1;
        color = schemeColor "highlightColor" "Window" 1;
      };
      margin = {
        enabled = true;
        side = {
          top = 6;
          bottom = 6;
          left = 8;
          right = 8;
        };
      };
      spacing = 6;
      shadow.background = softShadow 4;
    };
  };

  dockStyle = {
    nativePanel = {
      background.opacity = 0;
      floatingDialogs = true;
      floatingDialogsAllowOverride = true;
    };
    panel.normal = {
      enabled = true;
      blurBehind = true;
      backgroundColor = schemeColor "backgroundColor" "View" 0.1;
      radius = {
        enabled = true;
        corner = allCorners 14;
      };
      padding = {
        enabled = true;
        side = {
          left = 2;
          right = 2;
        };
      };
    };
    widgets.normal = {
      enabled = true;
      foregroundColor = schemeColor "textColor" "View" 1;
    };
  };

  titleBar = rightMargin: {
    applicationTitleBar = {
      layout.elements = [
        "windowIcon"
        "windowTitle"
      ];
      windowTitle = {
        source = "appName";
        hideEmptyTitle = true;
        margins = {
          left = 10;
          right = rightMargin;
          top = 0;
          bottom = 0;
        };
      };
    };
  };

  # plasma-manager's plasmusicToolbar writes some keys that Plasmusic 4 no
  # longer reads, so the keys come from its contents/config/main.xml.
  music = {
    name = "plasmusic-toolbar";
    config.General = {
      # With the automatic choice, Plasma's media multiplexer, the widget
      # stayed hidden while Spotify played and Brave had a stopped player
      # with no song (observed on nixos-rog). These identities come from each
      # player's MPRIS Identity property; another player, such as mpv, shows
      # only once its identity is added here.
      choosePlayerAutomatically = false;
      preferredPlayerIdentity = "Spotify,Brave Origin";
      useAlbumCoverAsPanelIcon = true;
      fallbackToIconWhenArtNotAvailable = true;
      skipBackwardControlInPanel = false;
      skipForwardControlInPanel = false;
    };
  };

  islandsStyle = {
    nativePanel = {
      background.opacity = 0;
      floatingDialogs = true;
      floatingDialogsAllowOverride = true;
    };
    widgets.normal = {
      enabled = true;
      blurBehind = true;
      backgroundColor = schemeColor "backgroundColor" "Window" 0.5;
      foregroundColor = schemeColor "highlightColor" "Window" 1;
      radius = {
        enabled = true;
        corner = allCorners 10;
      };
      border = {
        enabled = true;
        width = 1;
        color = schemeColor "highlightColor" "Window" 1;
      };
      # A drag over a bar with this spacing freezes plasmashell without
      # overlays/plasma-desktop.nix.
      spacing = 0;
      margin = {
        enabled = true;
        side = {
          top = 4;
          bottom = 4;
          left = 6;
          right = 6;
        };
      };
    };
  };

  tahoe = inputs.mac-tahoe.lib.mkPackages pkgs;
  tahoePlasmoids = pkgs.callPackage ../../pkgs/mac-tahoe-plasmoids.nix {
    src = inputs.mac-tahoe;
  };

  # The launcher's default icon, view-app-grid, is in neither Papirus nor
  # Gruvbox Plus; both have only its symbolic form.
  tahoeLauncher = {
    name = "org.kde.mac-tahoe-liquid-kde.launcher";
    config.General.icon = "view-app-grid-symbolic";
  };

  claudeAccounts = lib.optional config.oruc.plasma.claudeAccountsWidget "org.oruc.claudeaccounts";

  dock = {
    location = "bottom";
    height = 80;
    floating = true;
    hiding = "dodgewindows";
    lengthMode = "fit";
    alignment = "center";
    widgets = [
      {
        name = "org.kde.mac.tahoe.liquid.icontasks";
        config.General.launchers = config.oruc.plasma.dockLaunchers;
      }
      (colorizer dockStyle)
    ];
  };

  claudeAccountsWidget = pkgs.callPackage ../../pkgs/claude-accounts-widget.nix {
    claudeTools = pkgs.callPackage ../../pkgs/claude-tools.nix { };
  };
in
{
  options.oruc.plasma.claudeAccountsWidget = lib.mkEnableOption "the Claude accounts widget in the top bar";

  config = lib.mkIf isPlasma {
    home.packages = [
      kvitalsPackage
      pkgs.plasmusic-toolbar
      tahoe.task-manager
      tahoePlasmoids
    ]
    ++ lib.optional config.oruc.plasma.claudeAccountsWidget claudeAccountsWidget;

    # plasmashell loads a widget's QML once and keeps running it after a
    # switch installs a new widget package, so a running plasmashell would
    # call the tools of the old package. The stamp holds the widget path that
    # the running plasmashell last loaded; a switch that changes it restarts
    # plasmashell once, and a switch with no plasmashell running only records it.
    home.activation.restartPlasmashellOnWidget = lib.mkIf config.oruc.plasma.claudeAccountsWidget (
      let
        systemctl = lib.getExe' pkgs.systemd "systemctl";
      in
      lib.hm.dag.entryAfter [ "reloadSystemd" ] ''
        stamp="${config.xdg.stateHome}/plasmashell-widgets/claude-accounts-path"
        if [[ "$(cat "$stamp" 2>/dev/null)" != "${claudeAccountsWidget}" && ! -v DRY_RUN ]]; then
          runtime=''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}
          state=$(XDG_RUNTIME_DIR=$runtime ${systemctl} --user show -p ActiveState --value plasma-plasmashell.service 2>/dev/null || true)
          if [[ $state == inactive || $state == failed ]] \
            || { [[ $state == active ]] && XDG_RUNTIME_DIR=$runtime ${systemctl} --user restart plasma-plasmashell.service; }; then
            { mkdir -p "''${stamp%/*}" && echo "${claudeAccountsWidget}" > "$stamp"; } \
              || warnEcho "could not write $stamp; the next switch restarts plasmashell again."
          else
            warnEcho "plasmashell is ''${state:-unreachable} or did not restart; the Claude accounts widget runs its old code until the next switch or login."
          fi
          unset state runtime
        fi
        unset stamp
      ''
    );

    # plasmashell caches compiled QML in qmlcache. A cache file is named after
    # the qrc path only and is checked against the source's timestamp, which
    # rcc sets to SOURCE_DATE_EPOCH, fixed in every Nix build. After the task
    # manager changes, plasmashell would keep running its old QML. A running
    # plasmashell can write old entries back, so the cache is cleared just
    # before plasmashell starts, while nothing uses it. The leading "-" lets
    # plasmashell start when the step fails; the stamp then stays old, so the
    # next start tries again.
    xdg.configFile."systemd/user/plasma-plasmashell.service.d/tahoe-qmlcache.conf".text = ''
      [Service]
      ExecStartPre=-${pkgs.writeShellScript "tahoe-qmlcache" ''
        set -eu
        stamp="${config.xdg.stateHome}/tahoe-qmlcache/task-manager-path"
        if [[ "$(cat "$stamp" 2>/dev/null)" != "${tahoe.task-manager}" ]]; then
          rm -rf "${config.xdg.cacheHome}/plasmashell/qmlcache"
          mkdir -p "''${stamp%/*}"
          echo "${tahoe.task-manager}" > "$stamp"
        fi
      ''}
    '';

    programs.plasma = {
      workspace = {
        inherit wallpaper;
        wallpaperFillMode = "preserveAspectCrop";
      };

      panels =
        {
          bar = [
            {
              location = "top";
              height = 44;
              lengthMode = "fill";
              widgets = [
                "org.kde.plasma.kickerdash"
                (titleBar 0)
                "org.kde.plasma.panelspacer"
                "org.kde.plasma.digitalclock"
                "org.kde.plasma.panelspacer"
              ]
              ++ claudeAccounts
              ++ [
                kvitals
                "org.kde.plasma.systemtray"
                "org.kde.plasma.showdesktop"
                (colorizer topBarStyle)
              ];
            }
            dock
          ];
          islands = [
            {
              location = "top";
              height = 36;
              floating = true;
              widgets = [
                tahoeLauncher
                (titleBar 6)
                "org.kde.plasma.panelspacer"
                "org.kde.plasma.digitalclock"
                "org.kde.plasma.panelspacer"
                # At the end of the left island, Panel Colorizer drew the song
                # as a box of its own with a double border; here it joins the
                # island.
                music
              ]
              ++ claudeAccounts
              ++ [
                kvitals
                "org.kde.plasma.systemtray"
                "org.kde.plasma.showdesktop"
                (colorizerWith { islandsEnabled = true; } islandsStyle)
              ];
            }
            dock
          ];
        }
        .${config.oruc.plasma.panelLayout};
    };
  };
}
