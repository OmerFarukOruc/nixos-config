{ config, pkgs, ... }:
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

  setSpeed = pkgs.writeShellApplication {
    name = "case-fans-set";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      channels=(3 5 7)
      # PWM 65 stopped both D30-140 chains; PWM 72 runs them near 750 RPM.
      flat=72
      kick=255
      ${findHwmon}

      restore_on_failure() {
        local result=$?
        if ((result != 0)); then
          for ch in "''${channels[@]}"; do
            echo 2 >"$hw/pwm''${ch}_enable" || echo "Could not restore auto control on channel $ch" >&2
          done
        fi
      }
      trap restore_on_failure EXIT

      # A stopped fan needs full power to start turning.
      for ch in "''${channels[@]}"; do
        echo "$kick" >"$hw/pwm$ch"
        echo 1 >"$hw/pwm''${ch}_enable"
      done
      sleep 3
      for ch in "''${channels[@]}"; do
        echo "$flat" >"$hw/pwm$ch"
      done

      # The driver caches readings for one second.
      sleep 4
      for ch in "''${channels[@]}"; do
        rpm=$(<"$hw/fan''${ch}_input")
        if ((rpm == 0)); then
          echo "Fan channel $ch stopped at PWM $flat; restoring auto control" >&2
          exit 1
        fi
        echo "Fan channel $ch: PWM $flat, $rpm RPM"
      done
    '';
  };

  caseFans = pkgs.writeShellApplication {
    name = "case-fans";
    runtimeInputs = [
      pkgs.coreutils
      config.systemd.package
    ];
    text = ''
      channels=(3 5 7)
      sudo=()
      if [[ $(id -u) != 0 ]]; then sudo=(/run/wrappers/bin/sudo); fi
      ${findHwmon}

      status() {
        printf 'static: %s\n' "$(systemctl is-active case-fans.service || true)"
        for ch in "''${channels[@]}"; do
          case $(<"$hw/pwm''${ch}_enable") in
            1) mode=static ;;
            2) mode=auto ;;
            *) mode=unknown ;;
          esac
          label=$(cat "$hw/fan''${ch}_label" 2>/dev/null || echo "Fan $ch")
          echo "$label: $(<"$hw/fan''${ch}_input") rpm, pwm=$(<"$hw/pwm$ch"), mode=$mode"
        done
      }

      case ''${1:-status} in
        on) "''${sudo[@]}" systemctl restart case-fans.service ;;
        off)
          "''${sudo[@]}" systemctl stop case-fans.service
          for ch in "''${channels[@]}"; do
            echo 2 | "''${sudo[@]}" tee "$hw/pwm''${ch}_enable" >/dev/null
          done
          ;;
        toggle)
          if systemctl is-active --quiet case-fans.service; then "$0" off; else "$0" on; fi
          ;;
        status) status ;;
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
          3 | 5 | 7) owner=case-fans ;;
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
    description = "Phanteks D30 case fans at a low fixed speed";
    after = [ "systemd-modules-load.service" ];
    wants = [ "systemd-modules-load.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${setSpeed}/bin/case-fans-set";
    };
  };

  environment.systemPackages = [
    caseFans
    fanStatus
  ];
}
