{
  config,
  lib,
  osConfig,
  pkgs,
  ...
}:
let
  machine = osConfig.oruc.machine;
  laptop = machine.hasBattery;
  hybrid = machine.gpu == "hybrid";
  prime = osConfig.hardware.nvidia.prime;

  hex = width: n: lib.fixedWidthString width "0" (lib.toLower (lib.toHexString n));
  pciAddress =
    busId:
    let
      fields = lib.splitString ":" (lib.removePrefix "PCI:" busId);
      busAndDomain = map lib.toInt (lib.splitString "@" (lib.head fields) ++ [ "0" ]);
      bus = lib.head busAndDomain;
      domain = lib.elemAt busAndDomain 1;
      device = lib.toInt (lib.elemAt fields 1);
    in
    "${hex 4 domain}:${hex 2 bus}:${hex 2 device}.${lib.elemAt fields 2}";

  mangohudConfig =
    pciDev:
    { scheme, ... }:
    lib.generators.toKeyValue { } (
      style scheme // lib.optionalAttrs (pciDev != null) { pci_dev = pciAddress pciDev; }
    );

  style = scheme: {
    legacy_layout = 0;
    preset = "12,11,10";
    position = "top-left";
    font_size = 32;
    round_corners = 8;
    background_alpha = "0.65";
    background_color = scheme.base00;
    text_color = scheme.base05;
    text_outline_color = scheme.base00;
    horizontal_separator_color = scheme.base03;
    gpu_color = scheme.base0B;
    cpu_color = scheme.base0D;
    vram_color = scheme.base0E;
    ram_color = scheme.base0C;
    engine_color = scheme.base08;
    io_color = scheme.base09;
    frametime_color = scheme.base0B;
    media_player_color = scheme.base05;
    wine_color = scheme.base08;
    battery_color = scheme.base0A;
    network_color = scheme.base0C;
    gpu_load_change = 1;
    cpu_load_change = 1;
    fps_color_change = 1;
    gpu_load_color = "${scheme.base0B},${scheme.base0A},${scheme.base08}";
    cpu_load_color = "${scheme.base0B},${scheme.base0A},${scheme.base08}";
    fps_color = "${scheme.base08},${scheme.base0A},${scheme.base0B}";
  };

  row = name: value: "${name}=${toString value}";
  preset = number: rows: "[preset ${toString number}]\n" + lib.concatLines rows;
  sysfsRow = label: command: [
    (row "custom_text" label)
    (row "exec" command)
  ];

  compact = [
    (row "horizontal" 1)
    (row "hud_compact" 1)
    (row "fps" 1)
    (row "frame_timing" 0)
    (row "gpu_stats" 1)
    (row "cpu_stats" 1)
  ];
  panel = [
    (row "fps" 1)
    (row "frame_timing" 1)
    (row "gpu_stats" 1)
    (row "gpu_temp" 1)
    (row "gpu_power" 1)
    (row "vram" 1)
    (row "cpu_stats" 1)
    (row "cpu_temp" 1)
    (row "cpu_power" 1)
    (row "ram" 1)
    (row "graphs" "gpu_load,cpu_load")
  ]
  ++ lib.optional laptop (row "battery" 1);
  fullDetail = [
    (row "fps" 1)
    (row "fps_metrics" "avg,0.01")
    (row "frametime" 1)
    (row "frame_timing" 1)
    (row "gpu_name" 1)
    (row "gpu_stats" 1)
    (row "gpu_temp" 1)
    (row "gpu_junction_temp" 1)
    (row "gpu_mem_temp" 1)
    (row "gpu_core_clock" 1)
    (row "gpu_mem_clock" 1)
    (row "gpu_power" 1)
    (row "gpu_power_limit" 1)
    (row "gpu_fan" 1)
    (row "gpu_voltage" 1)
    (row "throttling_status" 1)
    (row "vram" 1)
    (row "cpu_stats" 1)
    (row "cpu_temp" 1)
    (row "cpu_power" 1)
    (row "cpu_mhz" 1)
    (row "core_load" 1)
    (row "core_bars" 1)
    (row "ram" 1)
    (row "swap" 1)
    (row "procmem" 1)
    (row "io_read" 1)
    (row "io_write" 1)
    (row "vulkan_driver" 1)
    (row "engine_version" 1)
    (row "dx_api" 1)
    (row "wine" 1)
    (row "winesync" 1)
    (row "arch" 1)
    (row "resolution" 1)
    (row "present_mode" 1)
    (row "display_server" 1)
    (row "time" 1)
  ]
  ++ lib.optionals laptop [
    (row "battery" 1)
    (row "battery_watt" 1)
    (row "battery_time" 1)
  ]
  ++ lib.optionals laptop (sysfsRow "Platform" "cat /sys/firmware/acpi/platform_profile")
  ++ sysfsRow "EPP" "cat /sys/devices/system/cpu/cpufreq/policy0/energy_performance_preference"
  ++ sysfsRow "Scheduler" "cut -d_ -f1,2 /sys/kernel/sched_ext/root/ops 2>/dev/null || echo eevdf"
  ++ lib.optionals laptop (sysfsRow "AC" "cat /sys/class/power_supply/AC*/online");

  withoutRows = names: lib.filter (line: !lib.elem (lib.head (lib.splitString "=" line)) names);
  presets =
    missingGpuSensors:
    lib.concatStringsSep "\n" [
      (preset 10 compact)
      (preset 11 panel)
      (preset 12 (withoutRows missingGpuSensors fullDetail))
    ];
  radeonMissingSensors = lib.optionals hybrid [
    "gpu_junction_temp"
    "gpu_mem_temp"
    "gpu_fan"
  ];

  nvidiaConfig = ".config/MangoHud/MangoHud-nvidia.conf";
  nvidiaPresets = "MangoHud/presets-nvidia.conf";
  gameNvidia = pkgs.writeShellApplication {
    name = "game-nvidia";
    runtimeInputs = [ pkgs.power-profiles-daemon ];
    text = ''
      export VK_LOADER_DRIVERS_SELECT='*nvidia*'
      export PROTON_DLSS_UPGRADE=1
      export MANGOHUD=1
      export MANGOHUD_CONFIGFILE=${config.home.homeDirectory}/${nvidiaConfig}
      export MANGOHUD_PRESETSFILE=${config.xdg.configHome}/${nvidiaPresets}
      run=(nvidia-offload "$@")
      if [[ $(</sys/class/power_supply/ACAD/online) == 1 ]]; then
        run=(powerprofilesctl launch --profile performance --reason game-nvidia -- "''${run[@]}")
      fi
      exec "''${run[@]}"
    '';
  };
in
lib.mkIf machine.features.gaming (
  lib.mkMerge [
    {
      oruc.themeFiles.".config/MangoHud/MangoHud.conf" = mangohudConfig (
        if hybrid then prime.amdgpuBusId else null
      );
      xdg.configFile."MangoHud/presets.conf".text = presets radeonMissingSensors;
      home.packages = [ pkgs.goverlay ];
    }
    (lib.mkIf hybrid {
      oruc.themeFiles.${nvidiaConfig} = mangohudConfig prime.nvidiaBusId;
      xdg.configFile.${nvidiaPresets}.text = presets (radeonMissingSensors ++ [ "gpu_voltage" ]);
      home.packages = [ gameNvidia ];
    })
  ]
)
