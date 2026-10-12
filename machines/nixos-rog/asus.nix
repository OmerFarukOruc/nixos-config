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
  # asusd writes these limits on every platform profile change, also one that
  # power-profiles-daemon makes. Each value stays inside the GA605W range of the
  # kernel's asus-armoury table; the battery range has no GPU limits. Quiet
  # takes the lowest value of each range.
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
  # The firmware takes the power limits above only while every fan follows a
  # custom curve. Points are (°C, PWM 0-255); both rise left to right.
  # Performance keeps the factory curve. Quiet is the factory curve with its
  # repeated top point traded for a first point that stops the fans below 50 °C.
  # The factory curve reaches its top speed at 76 °C, which four busy threads
  # pass; balanced reaches the same top speed at 94 °C, so light work stays
  # quieter, and it idles at the quiet curve's floor.
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
  services.asusd = {
    enable = true;
    # asusd reads every field here; a missing one makes it start from its
    # own defaults, which switch profiles. It copies this file into /etc and
    # may rewrite it at runtime; the next activation restores it.
    asusdConfig.text = ''
      (
          charge_control_end_threshold: 100,
          base_charge_control_end_threshold: 100,
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
          ac_profile_tunings: ${
            tunings {
              Quiet = {
                PptPl1Spl = 15;
                PptPl2Sppt = 35;
                PptPl3Fppt = 35;
                DgpuTgp = 55;
                NvDynamicBoost = 5;
                NvTempTarget = 75;
              };
              Balanced = {
                PptPl1Spl = 50;
                PptPl2Sppt = 70;
                PptPl3Fppt = 70;
                DgpuTgp = 70;
                NvDynamicBoost = 10;
                NvTempTarget = 83;
              };
              Performance = {
                PptPl1Spl = 80;
                PptPl2Sppt = 80;
                PptPl3Fppt = 80;
                DgpuTgp = 85;
                NvDynamicBoost = 20;
                NvTempTarget = 87;
              };
            }
          },
          dc_profile_tunings: ${
            tunings {
              Quiet = {
                PptPl1Spl = 25;
                PptPl2Sppt = 31;
                PptPl3Fppt = 45;
                NvTempTarget = 75;
              };
              Balanced = {
                PptPl1Spl = 30;
                PptPl2Sppt = 40;
                PptPl3Fppt = 55;
                NvTempTarget = 80;
              };
              Performance = {
                PptPl1Spl = 35;
                PptPl2Sppt = 44;
                PptPl3Fppt = 65;
                NvTempTarget = 87;
              };
            }
          },
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
          brightness: Med,
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
  # has no Print key; Fn+F6 sends Mod+Shift+S.
  environment.etc."niri/host.kdl".text = ''
    binds {
        XF86Launch3 { spawn "${lib.getExe' config.services.asusd.package "asusctl"}" "aura" "effect" "--next-mode"; }
        Mod+Shift+S { screenshot; }
    }
  '';

  # Reported elsewhere on this model to freeze the kernel when a USB-C device
  # is plugged in. The cost is the USB-C power source readout.
  boot.blacklistedKernelModules = [ "ucsi_acpi" ];
}
