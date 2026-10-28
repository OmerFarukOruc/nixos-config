{
  config,
  lib,
  ...
}:
let
  auraColour = {
    r = lib.toInt config.scheme."base09-rgb-r";
    g = lib.toInt config.scheme."base09-rgb-g";
    b = lib.toInt config.scheme."base09-rgb-b";
  };

  ronTuple = values: "(${lib.concatMapStringsSep ", " toString values})";
  tunings =
    profiles:
    "{${
      lib.concatStrings (
        lib.mapAttrsToList (profile: group: ''
          ${profile}: (
              enabled: true,
              group: {${
                lib.concatStrings (lib.mapAttrsToList (name: value: " ${name}: ${toString value},") group)
              } },
          ),
        '') profiles
      )
    }}";
  acTunings = {
    Quiet = {
      PptPl1Spl = 15;
      PptPl2Sppt = 35;
      PptPl3Fppt = 35;
      DgpuTgp = 55;
      NvDynamicBoost = 5;
      NvTempTarget = 75;
    };
    Balanced = {
      PptPl1Spl = 25;
      PptPl2Sppt = 35;
      PptPl3Fppt = 45;
      DgpuTgp = 55;
      NvDynamicBoost = 5;
      NvTempTarget = 75;
    };
    Performance = {
      PptPl1Spl = 35;
      PptPl2Sppt = 45;
      PptPl3Fppt = 60;
      DgpuTgp = 85;
      NvDynamicBoost = 20;
      NvTempTarget = 87;
    };
  };
  dcTunings = {
    Quiet = {
      PptPl1Spl = 25;
      PptPl2Sppt = 31;
      PptPl3Fppt = 45;
      NvTempTarget = 75;
    };
    Balanced = {
      PptPl1Spl = 25;
      PptPl2Sppt = 35;
      PptPl3Fppt = 45;
      NvTempTarget = 75;
    };
    Performance = {
      PptPl1Spl = 35;
      PptPl2Sppt = 44;
      PptPl3Fppt = 60;
      NvTempTarget = 87;
    };
  };
  armouryAttribute = {
    PptPl1Spl = "ppt_pl1_spl";
    PptPl2Sppt = "ppt_pl2_sppt";
    PptPl3Fppt = "ppt_pl3_fppt";
    DgpuTgp = "nv_tgp";
    NvDynamicBoost = "nv_dynamic_boost";
    NvTempTarget = "nv_temp_target";
  };
  profiles = import ./power-profiles.nix;
  sameNames = left: right: lib.sort builtins.lessThan left == lib.sort builtins.lessThan right;
  fanNames = [
    "CPU"
    "GPU"
    "MID"
  ];
  nonDecreasing =
    values:
    lib.all (index: builtins.elemAt values index <= builtins.elemAt values (index + 1)) (
      lib.genList (index: index) (lib.length values - 1)
    );
  curveOk =
    points:
    let
      temps = map lib.head points;
      pwms = map lib.last points;
    in
    lib.isList points
    && lib.length points == 8
    && lib.all (point: lib.isList point && lib.length point == 2) points
    && nonDecreasing temps
    && nonDecreasing pwms
    && lib.all (pwm: lib.isInt pwm && pwm >= 0 && pwm <= 255) pwms;
  badCurves = lib.concatMap (
    profile:
    lib.concatMap (
      fan:
      let
        points = fanCurveTable.${profile.fanCurveKey}.${fan} or null;
      in
      lib.optional (points == null || !curveOk points) "${profile.fanCurveKey}.${fan}"
    ) fanNames
  ) profiles;
  fanSetBad = lib.concatMap (
    profile:
    let
      names = lib.attrNames (fanCurveTable.${profile.fanCurveKey} or { });
    in
    lib.optional (
      fanCurveTable ? ${profile.fanCurveKey} && !sameNames names fanNames
    ) "${profile.fanCurveKey} fans ${toString names}"
  ) profiles;
  fanCurveTable = lib.importJSON ./fan-curves.json;
  fanCurves =
    profiles:
    lib.concatStrings (
      lib.mapAttrsToList (profile: fans: ''
        ${profile}: [
        ${
          lib.concatStrings (
            lib.mapAttrsToList (fan: points: ''
              (
                  fan: ${fan},
                  pwm: ${ronTuple (map lib.last points)},
                  temp: ${ronTuple (map lib.head points)},
                  enabled: true,
              ),
            '') fans
          )
        }],
      '') profiles
    );
  auraEffect = mode: ''
    ${mode}: (
        mode: ${mode},
        zone: r#None,
        colour1: (r: ${toString auraColour.r}, g: ${toString auraColour.g}, b: ${toString auraColour.b}),
        colour2: (r: 0, g: 0, b: 0),
        speed: Med,
        direction: Right,
    ),
  '';
in
assert lib.assertMsg (sameNames (lib.attrNames acTunings) (
  map (profile: profile.asusdTuningName) profiles
)) "AC tunings must use the asusd names in power-profiles.nix.";
assert lib.assertMsg (sameNames (lib.attrNames dcTunings) (
  map (profile: profile.asusdTuningName) profiles
)) "DC tunings must use the asusd names in power-profiles.nix.";
assert lib.assertMsg (sameNames (lib.attrNames fanCurveTable) (
  map (profile: profile.fanCurveKey) profiles
)) "fan-curves.json profiles must match power-profiles.nix.";
assert lib.assertMsg (badCurves == [ ] && fanSetBad == [ ])
  "fan-curves.json needs the fans CPU, GPU and MID, eight non-decreasing points, and PWM from 0 to 255: ${
    lib.concatStringsSep ", " (badCurves ++ fanSetBad)
  }";
{
  oruc.verifyFacts =
    let
      armouryFacts =
        source:
        lib.concatMapAttrs (
          profile:
          lib.mapAttrs' (
            name: value:
            lib.nameValuePair "armoury_${source}_${lib.toLower profile}_${armouryAttribute.${name}}" (
              toString value
            )
          )
        );
      fanFacts =
        profile:
        lib.concatMapAttrs (
          fan: points:
          let
            key = "${profile}_${lib.toLower fan}";
            list = values: lib.concatMapStringsSep "," toString values;
          in
          {
            "fan_temps_${key}" = list (map lib.head points);
            "fan_pwms_${key}" = list (map lib.last points);
          }
        );
    in
    armouryFacts "ac" acTunings
    // armouryFacts "dc" dcTunings
    // lib.concatMapAttrs fanFacts fanCurveTable;

  services.asusd = {
    enable = true;
    asusdConfig.text = ''
      (
          charge_control_end_threshold: 80,
          base_charge_control_end_threshold: 80,
          disable_nvidia_powerd_on_battery: true,
          ac_command: "",
          bat_command: "",
          platform_profile_linked_epp: false,
          platform_profile_on_battery: Balanced,
          change_platform_profile_on_battery: false,
          platform_profile_on_ac: Balanced,
          change_platform_profile_on_ac: false,
          profile_quiet_epp: Power,
          profile_balanced_epp: BalancePower,
          profile_custom_epp: Performance,
          profile_performance_epp: Performance,
          ac_profile_tunings: ${tunings acTunings},
          dc_profile_tunings: ${tunings dcTunings},
          armoury_settings: {
              PanelOverdrive: 1,
          },
      )
    '';
    fanCurvesConfig.text = ''
      (
          profiles: (
              ${fanCurves fanCurveTable}
              custom: [],
          ),
      )
    '';
    auraConfigs."19b6".text = ''
      (
          config_name: "aura_19b6.ron",
          brightness: High,
          current_mode: Static,
          builtins: {
              ${lib.concatMapStrings auraEffect [
                "Static"
                "Breathe"
                "RainbowCycle"
                "RainbowWave"
                "Pulse"
              ]}
          },
          multizone_on: false,
          enabled: (
              states: [
                  (zone: Keyboard, boot: true, awake: true, sleep: false, shutdown: false),
              ],
          ),
      )
    '';
  };
  systemd.services.asusd.restartTriggers = lib.mapAttrsToList (_: file: file.source) (
    lib.filterAttrs (name: _: lib.hasPrefix "asusd/" name) config.environment.etc
  );

  environment.etc."asusd/slash.ron" = {
    mode = "0644";
    text = ''
      (
          enabled: true,
          brightness: 255,
          display_interval: 0,
          display_mode: Static,
          show_on_boot: true,
          show_on_shutdown: true,
          show_on_sleep: true,
          show_on_battery: false,
          show_battery_warning: true,
          show_on_lid_closed: true,
      )
    '';
  };

  environment.etc."niri/host.kdl".text = ''
    binds {
        XF86Launch3 { spawn "${lib.getExe' config.services.asusd.package "asusctl"}" "aura" "effect" "--next-mode"; }
        Mod+Shift+S { screenshot; }
    }
  '';

  # One GA605WI owner's config (github.com/rajeevmen0n/nix, hosts/ga605wi)
  # blacklists it with the comment "kernel freeze when type c port is used";
  # we found no other report of it. The cost is the USB-C power source readout.
  boot.blacklistedKernelModules = [ "ucsi_acpi" ];
}
