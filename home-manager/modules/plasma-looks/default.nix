{
  config,
  lib,
  osConfig,
  pkgs,
  sessions,
  ...
}:
let
  selectors = import ../../../machines/selectors.nix;
  isPlasma = sessions.hasDesktop osConfig.oruc.machine "plasma";
  defaultLook =
    if isPlasma then
      osConfig.oruc.machine.theme.plasmaLook
    else
      builtins.head selectors.plasmaLookNames;
  looks = {
    glass = {
      colorScheme = "OrucBase16Glass";
      plasmaStyle = _: "oruc-glass";
    };
    klassy = {
      colorScheme = "OrucBase16";
      plasmaStyle = polarity: "klassy-${polarity}";
    };
  };

  current = "${config.oruc.themeState}/theme/current";
  kreadconfig = lib.getExe' pkgs.kdePackages.kconfig "kreadconfig6";
  kwriteconfig = lib.getExe' pkgs.kdePackages.kconfig "kwriteconfig6";

  kdeColors = pkgs.writeShellApplication {
    name = "oruc-kde-colors";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.diffutils
      pkgs.gnused
      pkgs.kdePackages.plasma-workspace
    ];
    text = ''
      base=$1
      dir=${config.xdg.dataHome}/color-schemes
      render() {
        sed -e "s/^ColorScheme=.*/ColorScheme=$1/" -e "s/^Name=.*/& ''${1#"$base"}/" \
          ${current}/.local/share/oruc/kde/"$base".colors
      }
      running=$(${kreadconfig} --file kdeglobals --group General --key ColorScheme)
      case $running in
        "''${base}A" | "''${base}B")
          if render "$running" | cmp -s - "$dir/$running.colors"; then
            exit 0
          fi
          ;;
      esac
      name=''${base}A
      [[ $running != "$name" ]] || name=''${base}B
      mkdir -p "$dir"
      render "$name" >"$dir/$name.colors.tmp"
      mv -T "$dir/$name.colors.tmp" "$dir/$name.colors"
      plasma-apply-colorscheme "$name"
    '';
  };

  reconfigureGlass = pkgs.writeShellApplication {
    name = "oruc-reconfigure-glass";
    runtimeInputs = [ pkgs.systemd ];
    text = ''
      if busctl --user status org.kde.KWin >/dev/null 2>&1; then
        busctl --user call org.kde.KWin /Effects org.kde.kwin.Effects reconfigureEffect s glass
      fi
    '';
  };

  plasmaLive = pkgs.writeShellApplication {
    name = "oruc-plasma-live";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.kdePackages.plasma-workspace
    ];
    text = ''
      login=
      if [[ ''${1:-} == --login ]]; then
        login=--login
        shift
      fi
      look=$1
      if [[ -z $login ]]; then
        case $(${kreadconfig} --file kdeglobals --group General --key ColorScheme) in
          ${lib.concatMapAttrsStringSep "\n    " (
            name: look: "${look.colorScheme} | ${look.colorScheme}A | ${look.colorScheme}B) look=${name} ;;"
          ) looks}
        esac
      fi
      polarity=$(cat ${current}/.oruc/polarity)
      case $look in
        ${lib.concatMapAttrsStringSep "\n  " (
          name: look: "${name}) base=${look.colorScheme} style=${look.plasmaStyle "$polarity"} ;;"
        ) looks}
        *)
          echo "oruc-plasma-live: unknown look $look" >&2
          exit 64
          ;;
      esac
      ${lib.getExe kdeColors} "$base"
      ${lib.getExe config.oruc.applyPolarity} $login
      plasma-apply-desktoptheme "$style"
      if [[ $base == ${looks.glass.colorScheme} ]]; then
        glow=$(cat ${current}/.oruc/glow)
        if [[ $(${kreadconfig} --file kwinrc --group Effect-blurplus --key GlowColor) != "$glow" ]]; then
          ${kwriteconfig} --file kwinrc --group Effect-blurplus --key GlowColor "$glow"
          ${lib.getExe reconfigureGlass}
        fi
      fi
    '';
  };
in
{
  imports = map (name: ./. + "/${name}.nix") selectors.plasmaLookNames;

  options.oruc.plasma = {
    look = lib.mkOption {
      type = lib.types.enum selectors.plasmaLookNames;
      default = defaultLook;
      description = "The Plasma look of this generation.";
    };
    colorScheme = lib.mkOption {
      type = lib.types.enum (lib.mapAttrsToList (_: look: look.colorScheme) looks);
      readOnly = true;
      default = looks.${config.oruc.plasma.look}.colorScheme;
      description = "Base name of the KDE color scheme of this look. oruc-kde-colors applies it as <name>A or <name>B, whichever kdeglobals does not name, from the colours file of the same name in the theme pack.";
    };
    widgetStyle = lib.mkOption {
      type = lib.types.str;
      description = "Qt style that oruc-plasma-colors applies with the color scheme.";
    };
    dockLaunchers = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "preferred://filemanager"
        "applications:io.missioncenter.MissionCenter.desktop"
        "preferred://browser"
        "applications:com.mitchellh.ghostty.desktop"
        "applications:SourceGit.desktop"
        "applications:code.desktop"
        "applications:com.anthropic.Claude.desktop"
        "applications:discord.desktop"
        "applications:org.telegram.desktop.desktop"
        "applications:spotify.desktop"
      ];
      description = "Launchers pinned to the dock of every look.";
    };
    kdeColors = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      default = kdeColors;
      description = "oruc-kde-colors BASE: applies the stored scheme's KDE colours of BASE (OrucBase16 or OrucBase16Glass) to the running session.";
    };
    live = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      default = plasmaLive;
      description = "oruc-plasma-live [--login] LOOK: applies the stored scheme's KDE colours, its dark or light set, the look's Plasma style and, with the Glass colours, the Glass glow. Without --login it keeps the look whose KDE colour scheme runs, and uses LOOK only when another colour scheme runs.";
    };
    reconfigureGlass = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      default = reconfigureGlass;
      description = "oruc-reconfigure-glass: makes a running KWin read the Glass effect's settings again.";
    };
    panelLayout = lib.mkOption {
      type = lib.types.enum [
        "bar"
        "islands"
      ];
      default = "bar";
      description = ''
        Panels from plasma-panels.nix: one top bar, or a floating top bar
        of three islands, each with the dock.
      '';
    };
  };

  config = lib.mkIf isPlasma {
    # Glass reads #AARRGGBB, so 10 is the alpha.
    oruc.themeFacts.glow = { scheme, ... }: "#10${scheme.base0D}";
  };
}
