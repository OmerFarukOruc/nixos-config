# The Plasma looks of oruc (home-manager/modules/plasma-looks). The default
# look is the Home Manager generation itself, and every other look is one of
# its specialisations. `plasma-look <look>` activates a look and stores the
# choice. Each deploy and each boot activates the default look again, so the
# Home Manager service then activates the stored look.
{
  config,
  lib,
  pkgs,
  sessions,
  ...
}:
let
  cfg = config.oruc.machine;
  hasPlasma = sessions.hasDesktop cfg "plasma";
  hm = config.home-manager.users.oruc;
  defaultLook = cfg.theme.plasmaLook;
  lookConfigs = {
    ${defaultLook} = hm;
  }
  // lib.mapAttrs (_: specialisation: specialisation.configuration) hm.specialisation;
  looks = lib.attrNames lookConfigs;
  # Home Manager's own service passes the same version.
  driverVersion = if config.home-manager.enableLegacyProfileManagement then "0" else "1";

  pluginSwitches =
    look: lib.attrNames (lookConfigs.${look}.programs.plasma.configFile.kwinrc.Plugins or { });
  allSwitches = lib.unique (lib.concatMap pluginSwitches looks);
  missingSwitches = lib.filterAttrs (_: missing: missing != [ ]) (
    lib.genAttrs looks (look: lib.subtractLists (pluginSwitches look) allSwitches)
  );

  plasmaLook = pkgs.writeShellApplication {
    name = "plasma-look";
    runtimeInputs = with pkgs; [
      coreutils
      gnused
      systemd
    ];
    text = ''
      state=''${XDG_STATE_HOME:-$HOME/.local/state}/oruc/plasma-look
      base=${hm.home.activationPackage}
      default=${defaultLook}
      looks=(${lib.escapeShellArgs looks})

      usage() {
        cat <<EOF
      Usage: plasma-look [LOOK | --reapply]

      With no argument, prints the active Plasma look and the looks to choose from.
      LOOK activates that look and keeps it across deploys; log out and in to
      load its colors, Plasma style, panels and KWin effects.
      --reapply activates the stored look again. The Home Manager service runs it
      after it activates the default look.
      EOF
      }

      activate() {
        # The session's display and bus, as Home Manager's own service imports
        # them, so the activation reaches KWin from SSH or a system unit too.
        if [[ -z ''${DBUS_SESSION_BUS_ADDRESS:-} ]]; then
          eval "$(
            XDG_RUNTIME_DIR=''${XDG_RUNTIME_DIR:-/run/user/$(id -u)} systemctl --user show-environment 2>/dev/null |
              sed -En '/^(DBUS_SESSION_BUS_ADDRESS|DISPLAY|WAYLAND_DISPLAY|XAUTHORITY|XDG_RUNTIME_DIR)=/s/^/export /p'
          )"
        fi
        if [[ $1 == "$default" ]]; then
          "$base/activate" --driver-version ${driverVersion}
        else
          "$base/specialisation/$1/activate" --driver-version ${driverVersion}
        fi
      }

      stored() {
        cat "$state" 2>/dev/null || echo "$default"
      }

      case ''${1:-} in
        "")
          echo "active: $(stored)"
          echo "looks: ''${looks[*]} (default: $default)"
          ;;
        -h | --help) usage ;;
        --reapply)
          look=$(stored)
          [[ $look == "$default" ]] && exit 0
          if [[ ! -x $base/specialisation/$look/activate ]]; then
            echo "plasma-look: the stored look $look no longer exists; the default look $default stays" >&2
            exit 0
          fi
          activate "$look"
          ;;
        *)
          look=$1
          if [[ " ''${looks[*]} " != *" $look "* ]]; then
            usage >&2
            exit 64
          fi
          activate "$look"
          mkdir -p "$(dirname "$state")"
          echo "$look" >"$state"
          echo "Log out and in to load the $look look's colors, Plasma style, panels and KWin effects."
          ;;
      esac
    '';
  };
in
{
  config = lib.mkIf hasPlasma {
    assertions = [
      {
        # The names become shell variable names in /etc/oruc/verify-facts.
        assertion = lib.all (look: builtins.match "[a-z0-9]+" look != null) looks;
        message = "Plasma look names may hold only lowercase letters and digits: ${toString looks}";
      }
      {
        assertion = missingSwitches == { };
        message =
          "Every Plasma look must write the same kwinrc Plugins switches, because plasma-manager "
          + "never removes a key that a look leaves out. Missing: "
          + lib.concatStringsSep "; " (
            lib.mapAttrsToList (look: missing: "${look}: ${lib.concatStringsSep ", " missing}") missingSwitches
          );
      }
    ];

    environment.systemPackages = [ plasmaLook ];

    # The leading "-" keeps a failed look from failing the unit, because a
    # failed unit makes deploy.sh roll back the whole system. The default
    # look then stays, and the unit's journal holds the error.
    systemd.services.home-manager-oruc.serviceConfig.ExecStartPost =
      "-${lib.getExe plasmaLook} --reapply";

    # scripts/verify-nixos-rog.sh checks that each panel widget of the stored
    # look is installed, and that each KWin effect it turns on is loaded.
    oruc.verifyFacts = {
      plasma_look_default = defaultLook;
    }
    // lib.concatMapAttrs (
      look: lookConfig:
      let
        plasma = lookConfig.programs.plasma;
        effects = lib.filterAttrs (key: setting: lib.hasSuffix "Enabled" key && setting.value == true) (
          plasma.configFile.kwinrc.Plugins or { }
        );
        widgets = lib.concatMap (panel: map (widget: widget.name) panel.widgets) plasma.panels;
        list = names: lib.concatStringsSep "," (lib.unique names);
      in
      lib.optionalAttrs (widgets != [ ]) { "plasma_widgets_${look}" = list widgets; }
      // lib.optionalAttrs (effects != { }) {
        "kwin_effects_${look}" = list (map (lib.removeSuffix "Enabled") (lib.attrNames effects));
      }
    ) lookConfigs;

    # scripts/verify-nixos-rog.sh compares the panel file after a panel build
    # with the settings of the stored look (scripts/lib/plasma-panel-settings.py).
    # The values hold slashes and JSON, which verify-facts does not allow.
    environment.etc = lib.mapAttrs' (
      look: lookConfig:
      lib.nameValuePair "oruc/verify-plasma-panels/${look}.json" {
        text = builtins.toJSON (
          map (panel: {
            inherit (panel) location;
            widgets = map (widget: { inherit (widget) name config; }) panel.widgets;
          }) lookConfig.programs.plasma.panels
        );
      }
    ) lookConfigs;
  };
}
