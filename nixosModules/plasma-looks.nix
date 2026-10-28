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
  variantRow =
    look: scheme:
    lib.findFirst (
      row: (row.look or null) == look && row.scheme == scheme
    ) (throw "No Plasma variant for look ${toString look} and scheme ${scheme}") variants.rows;
  variantConfig =
    look: scheme:
    let
      row = variantRow look scheme;
    in
    if row.generation then hm else hm.specialisation.${row.name}.configuration;
  lookConfigs = lib.genAttrs variants.looks (look: variantConfig look variants.defaultScheme);
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

    oruc.verifyFacts = {
      plasma_look_default = variants.defaultLook;
      scheme_default = variants.defaultScheme;
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

    environment.etc = lib.listToAttrs (
      map
        (
          variant:
          lib.nameValuePair "oruc/verify-plasma-panels/${(variantRow variant.look variant.scheme).name}.json"
            {
              text = builtins.toJSON (
                map (panel: {
                  inherit (panel) location;
                  widgets = map (widget: { inherit (widget) name config; }) panel.widgets;
                }) (variantConfig variant.look variant.scheme).programs.plasma.panels
              );
            }
        )
        (
          lib.cartesianProduct {
            look = looks;
            scheme = variants.schemes;
          }
        )
    );
  };
}
