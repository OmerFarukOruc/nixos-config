# ASUS platform control. power-profiles-daemon owns the platform profile, EPP
# and boost; asusd keeps the fans, the charge limit, Aura and the armoury
# settings. Only one of them may switch profiles, so asusd's profile switching
# and its EPP link are off.
{
  config,
  lib,
  ...
}:
let
  # #ff5200
  auraColour = {
    r = 255;
    g = 82;
    b = 0;
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
  # asusd writes these limits on every platform profile change, also one that
  # power-profiles-daemon makes. Each value stays inside the GA605W range of the
  # kernel's asus-armoury table; on battery the only GPU limit is the
  # temperature target. Quiet takes each range's minimum and performance each
  # GPU range's maximum; the other values trade speed for heat and fan noise.
  # In a 4-minute all-thread stress-ng run on AC, the CPU peaked at 62 °C in
  # quiet (boost off), 75 °C in balanced and 81 °C in performance. The fan
  # curves' first points changed after that run. Rerun it with
  # scripts/thermal-test-rog.sh (docs/nixos-rog.md, Power and heat).
  # cpu-limits.nix caps each profile's CPU temperature.
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
  # The asus-armoury attribute that asusd writes each tuning to.
  armouryAttribute = {
    PptPl1Spl = "ppt_pl1_spl";
    PptPl2Sppt = "ppt_pl2_sppt";
    PptPl3Fppt = "ppt_pl3_fppt";
    DgpuTgp = "nv_tgp";
    NvDynamicBoost = "nv_dynamic_boost";
    NvTempTarget = "nv_temp_target";
  };
  # The firmware takes the power limits above only while every fan follows a
  # custom curve. fan-curves.json maps each profile (quiet, balanced,
  # performance) and each fan (CPU, GPU, MID) to 8 points of (°C, PWM 0-255);
  # neither value falls from left to right. The kernel sends each point as
  # 100 * PWM / 255 percent, rounded down, and in a sweep on 2026-10-13 every
  # fan started from stop at 1 % (PWM 3); PWM 0-2 send 0 %, which stops the
  # fan. The firmware also runs each fan at its first point's speed below that
  # point's temperature. So the CPU and GPU fans start at PWM 3 and never stop.
  # The MID fan starts at 0 and stops when cool, because at 1 % it turns at
  # 3400-4300 rpm, against about 2200 for the others.
  # The CPU curve ends at 82 °C with PWM 104 in quiet, at 94 °C with 165 in
  # balanced and at 86 °C with 200 in performance.
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
{
  # verify-nixos-rog.sh compares the live armoury limits and fan curves of each
  # platform profile with these.
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
    # asusd reads every field here; a missing one makes it start from its
    # own defaults, which switch profiles. It copies this file into /etc and
    # may rewrite it at runtime; the next activation restores it.
    # The 80% charge limit is ASUS's Balanced mode; `asusctl battery oneshot`
    # charges to 100% once, such as before a trip.
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
    # The keyboard is one RGB zone. It takes auraColour in every
    # mode the Aura key cycles through, and stays dark while asleep and off.
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
  # asusd reads most of its files only when it starts. It reloads a changed
  # asusd.ron, but kept applying the old power limits after that, so every
  # change restarts it.
  systemd.services.asusd.restartTriggers = lib.mapAttrsToList (_: file: file.source) (
    lib.filterAttrs (name: _: lib.hasPrefix "asusd/" name) config.environment.etc
  );

  # The Slash LED bar on the lid stays dark on battery. The asusd module has no
  # option for this file.
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

  # The Aura key sends XF86Launch3; asusctl 6.5.0 has no `aura -n`. The laptop
  # has no Print key; Fn+F6 sends Mod+Shift+S. These binds append to
  # /etc/niri/host.kdl, which nixosModules/desktop.nix and graphics.nix also
  # write; config.kdl includes the merged text.
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
