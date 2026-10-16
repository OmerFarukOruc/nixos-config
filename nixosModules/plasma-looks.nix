# Checks of the Plasma looks of oruc (home-manager/modules/plasma-looks).
# `plasma-look` comes from hm-variants.nix. The facts below describe each look
# with the record's scheme, because the scheme does not change its widgets or
# effects.
{
  config,
  lib,
  sessions,
  ...
}:
let
  cfg = config.oruc.machine;
  hasPlasma = sessions.hasDesktop cfg "plasma";
  hm = config.home-manager.users.oruc;
  variants = import ../machines/variants.nix { inherit lib sessions; } cfg;
  lookConfigs = lib.genAttrs (lib.remove null variants.looks) (
    look:
    if look == variants.defaultLook then
      hm
    else
      hm.specialisation.${variants.name look variants.defaultScheme}.configuration
  );
  looks = lib.attrNames lookConfigs;

  pluginSwitches =
    look: lib.attrNames (lookConfigs.${look}.programs.plasma.configFile.kwinrc.Plugins or { });
  allSwitches = lib.unique (lib.concatMap pluginSwitches looks);
  missingSwitches = lib.filterAttrs (_: missing: missing != [ ]) (
    lib.genAttrs looks (look: lib.subtractLists (pluginSwitches look) allSwitches)
  );

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

    # scripts/verify-nixos-rog.sh checks that each panel widget of the stored
    # look is installed, and that each KWin effect it turns on is loaded.
    oruc.verifyFacts = {
      plasma_look_default = variants.defaultLook;
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
