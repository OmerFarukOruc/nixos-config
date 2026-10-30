{
  config,
  lib,
  pkgs,
  ...
}:
let
  findHwmon = ''
    hw=""
    for d in /sys/class/hwmon/hwmon*; do
      [[ -r $d/name ]] || continue
      if [[ $(<"$d/name") == nct6687 ]]; then
        hw=$d
        break
      fi
    done
    [[ -n $hw ]] || {
      echo "nct6687 hwmon not found" >&2
      exit 1
    }
  '';

  tables = lib.importJSON ./fan-tables.json;
  owned = [
    tables.radiator.channel
    tables.rear.channel
  ]
  ++ map (intake: intake.channel) tables.intakes;
  ownedList = lib.concatMapStringsSep "," toString owned;

  control = pkgs.writers.writePython3Bin "case-fans-control" { } (builtins.readFile ./fan-control.py);

  settings = {
    period_s = 2;
    cpu = {
      hwmon = "k10temp";
      label = "Tctl";
      rise_s = 10;
      fall_s = 45;
    };
    gpu = {
      hwmon = "amdgpu";
      label = "edge";
      rise_s = 5;
      fall_s = 30;
    };
    inherit (tables) radiator rear intakes;
    radiator_curve = [
      [
        55
        500
      ]
      [
        65
        650
      ]
      [
        75
        900
      ]
      [
        80
        1300
      ]
      [
        85
        1800
      ]
    ];
    intake_curve = [
      [
        50
        600
      ]
      [
        60
        800
      ]
      [
        70
        1100
      ]
      [
        80
        1500
      ]
      [
        85
        1800
      ]
    ];
    rear_rpm = 450;
    pressure = {
      radiator = 0.85;
      rear = 0.30;
    };
    emergency = {
      enter_filtered_c = 85;
      enter_raw_c = 89;
      leave_filtered_c = 80;
      leave_s = 30;
    };
  };
  configFile = pkgs.writeText "case-fans.json" (builtins.toJSON settings);

  caseFans = pkgs.writeShellApplication {
    name = "case-fans";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.jq
      config.systemd.package
    ];
    text = ''
      sudo=()
      if [[ $(id -u) != 0 ]]; then sudo=(/run/wrappers/bin/sudo); fi

      case ''${1:-status} in
        on)
          "''${sudo[@]}" systemctl reset-failed case-fans.service
          "''${sudo[@]}" systemctl restart case-fans.service
          ;;
        off) "''${sudo[@]}" systemctl stop case-fans.service ;;
        toggle)
          if systemctl is-active --quiet case-fans.service; then "$0" off; else "$0" on; fi
          ;;
        status)
          printf 'case-fans: %s\n' "$(systemctl is-active case-fans.service || true)"
          if [[ -r /run/case-fans/state.json ]]; then jq . /run/case-fans/state.json; fi
          ;;
        *)
          echo "usage: case-fans on|off|toggle|status" >&2
          exit 2
          ;;
      esac
    '';
  };

  fanStatus = pkgs.writeShellApplication {
    name = "fan-status";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      ${findHwmon}
      printf '%-16s %7s %5s %-7s %s\n' FAN RPM PWM MODE OWNER
      for f in "$hw"/fan[0-9]_input; do
        n=$(basename "$f" _input)
        idx=''${n#fan}
        rpm=$(<"$f")
        ((rpm == 0)) && continue
        label=$(cat "$hw/''${n}_label" 2>/dev/null || echo "$n")
        pwm=$(cat "$hw/pwm$idx" 2>/dev/null || echo -)
        case $(cat "$hw/pwm''${idx}_enable" 2>/dev/null) in
          1) mode=manual ;;
          2) mode=auto ;;
          *) mode="?" ;;
        esac
        case $idx in
          ${lib.concatMapStringsSep " | " toString owned}) owner=case-fans ;;
          *) owner=BIOS ;;
        esac
        printf '%-16s %7s %5s %-7s %s\n' "$label" "$rpm" "$pwm" "$mode" "$owner"
      done
    '';
  };
in
{
  # Out-of-tree driver for the board's Nuvoton NCT6687-R. The kernel's own
  # nct6683 reads the chip but cannot set fan speeds.
  boot.extraModulePackages = [ config.boot.kernelPackages.nct6687d ];
  boot.kernelModules = [ "nct6687" ];

  systemd.services.case-fans = {
    description = "Case and radiator fans on an RPM loop with positive pressure";
    after = [ "systemd-modules-load.service" ];
    wants = [ "systemd-modules-load.service" ];
    wantedBy = [ "multi-user.target" ];
    startLimitIntervalSec = 600;
    startLimitBurst = 3;
    serviceConfig = {
      Type = "notify";
      ExecStart = "${control}/bin/case-fans-control --config ${configFile}";
      ExecStopPost = "${control}/bin/case-fans-control --restore ${ownedList}";
      WatchdogSec = "10s";
      WatchdogSignal = "SIGKILL";
      TimeoutStartSec = "30s";
      TimeoutStopSec = "5s";
      Restart = "on-failure";
      RestartSec = 5;
      RuntimeDirectory = "case-fans";
    };
  };

  environment.systemPackages = [
    caseFans
    control
    fanStatus
  ];
}
