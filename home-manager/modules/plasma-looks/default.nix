# A Plasma look is one file in this directory that sets the Plasma style, the
# window decoration, the Qt style, the color scheme and the KWin effects that
# belong together. The machine record names the default look
# (theme.plasmaLook). Every other look is a Home Manager specialisation of the
# same generation, which `plasma-look` (nixosModules/plasma-looks.nix)
# activates without a rebuild.
#
# A look writes its keys only while it is active, and plasma-manager never
# removes a key that a look leaves out. So a look writes its own KWin plugin switches
# as false while another look is active, and nixosModules/plasma-looks.nix
# rejects looks that name different plugin switches.
#
# A specialisation cannot install packages, because NixOS installs the
# packages of the default look only (useUserPackages). So each look installs
# its packages while any look is active.
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
  defaultLook = osConfig.oruc.machine.theme.plasmaLook;
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
      type = lib.types.str;
      description = "Color scheme that oruc-plasma-colors applies at each Plasma login.";
    };
    widgetStyle = lib.mkOption {
      type = lib.types.str;
      description = "Qt style that oruc-plasma-colors applies with the color scheme.";
    };
    dockLaunchers = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      # The Teams and WhatsApp Web entries are web apps that Brave writes to
      # ~/.local/share/applications.
      default = [
        "preferred://filemanager"
        "applications:io.missioncenter.MissionCenter.desktop"
        "preferred://browser"
        "applications:com.mitchellh.ghostty.desktop"
        "applications:SourceGit.desktop"
        "applications:code.desktop"
        "applications:chatgpt.desktop"
        "applications:com.anthropic.Claude.desktop"
        "applications:grok-bot.desktop"
        "applications:openchamber.desktop"
        "applications:cursor.desktop"
        "applications:org.opengamingcollective.rog-control-center.desktop"
        "applications:slack.desktop"
        "applications:brave-ompifgpmddkgmclendfeacglnodjjndh-Default.desktop"
        "applications:brave-hnpfjngllnobngcgfapefoaidbinmjnm-Default.desktop"
        "applications:discord.desktop"
        "applications:org.telegram.desktop.desktop"
        "applications:spotify.desktop"
        "applications:md.obsidian.Obsidian.desktop"
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
    specialisation = lib.genAttrs (lib.remove defaultLook selectors.plasmaLookNames) (look: {
      configuration.oruc.plasma.look = look;
    });

    # The units that run once per login (once-per-login.nix) would still run
    # at the first switch into a session that started before their marker
    # existed, so the activation marks the running login for them before
    # Home Manager starts units.
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
