{
  lib,
  osConfig,
  pkgs,
  sessions,
  ...
}:
let
  machine = osConfig.oruc.machine;
  isNiri = sessions.hasDesktop machine "niri";
  idle = if machine.hasBattery then machine.idle else { inherit (machine.idle) ac; };

  oruc-idle = pkgs.writeShellApplication {
    name = "oruc-idle";
    runtimeInputs = [
      pkgs.brightnessctl
      pkgs.coreutils
      pkgs.niri
    ];
    text = ''
      dimmed=''${XDG_RUNTIME_DIR:?}/oruc-idle-dimmed
      shopt -s nullglob

      power_state() {
        local supply
        for supply in /sys/class/power_supply/*; do
          # A wireless mouse or headset reports its own battery with scope Device.
          if [[ $(<"$supply/type") == Battery && $(<"$supply/status") == Discharging ]] &&
            ! [[ -e $supply/scope && $(<"$supply/scope") == Device ]]; then
            echo battery
            return
          fi
        done
        echo ac
      }

      if [[ $1 == undim ]]; then
        if [[ -e $dimmed ]]; then
          for device in /sys/class/backlight/*_b*; do
            brightnessctl --quiet --device "''${device##*/}" --restore
          done
          rm -f "$dimmed"
        fi
        exit 0
      fi

      [[ $(power_state) == "$1" ]] || exit 0
      if [[ $2 == dim ]]; then
        for device in /sys/class/backlight/*_b*; do
          current=$(<"$device/brightness")
          brightnessctl --quiet --device "''${device##*/}" --save --min-value=1 set $((current * 3 / 10))
        done
        touch "$dimmed"
      else
        niri msg action power-off-monitors
      fi
    '';
  };

  exe = lib.getExe oruc-idle;
  timeouts = lib.concatLists (
    lib.mapAttrsToList (
      power: seconds:
      lib.optional (seconds.dimSeconds != null) {
        timeout = seconds.dimSeconds;
        command = "${exe} ${power} dim";
        resumeCommand = "${exe} undim";
      }
      ++ lib.optional (seconds.screenOffSeconds != null) {
        timeout = seconds.screenOffSeconds;
        command = "${exe} ${power} screen-off";
      }
    ) idle
  );
in
lib.mkIf isNiri {
  services.swayidle = {
    enable = timeouts != [ ];
    inherit timeouts;
  };
  oruc.sessionServices = lib.mkIf (timeouts != [ ]) { swayidle = "niri"; };
}
