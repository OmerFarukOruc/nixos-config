{
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
      type = lib.types.enum [
        "OrucBase16"
        "OrucBase16Glass"
      ];
      description = "Color scheme that oruc-plasma-colors applies at each Plasma login. The two ids are the schemes plasma-looks/kde-color-scheme.nix emits.";
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
    home.activation.markPlasmaLogin =
      let
        systemctl = lib.getExe' pkgs.systemd "systemctl";
      in
      lib.hm.dag.entryBefore [ "reloadSystemd" ] ''
        runtime=''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}
        login=$(XDG_RUNTIME_DIR=$runtime ${systemctl} --user show -p InvocationID --value plasma-workspace.target 2>/dev/null || true)
        if [[ -n $login && ! -v DRY_RUN ]]; then
          for unit in oruc-plasma-colors; do
            printf '%s\n' "$login" >"$runtime/$unit.login"
          done
        fi
      '';
  };
}
