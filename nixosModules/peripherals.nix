{
  config,
  lib,
  pkgs,
  sessions,
  ...
}:
let
  cfg = config.oruc.machine;
  isNiri = sessions.hasDesktop cfg "niri";
in
lib.mkIf (cfg.kind == "workstation") {
  hardware.bluetooth = {
    enable = true;
    powerOnBoot = false;
  };
  services.blueman.enable = isNiri;

  services.udisks2.enable = true;
  # The battery widgets of the desktop shells read UPower.
  services.upower.enable = cfg.hasBattery;

  # Writes the platform profile through the shell's power menu. Plasma enables
  # the daemon by default, and this normal-priority value keeps it off there.
  services.power-profiles-daemon.enable = isNiri;
  # The daemon starts at boot rather than on the first D-Bus call, and starts
  # in the profile last set, which it keeps in its state file. Without a saved
  # profile, as on its first start, it would keep the one it finds, which can
  # be the firmware's performance mode, so it starts in balanced then.
  systemd.services.power-profiles-daemon = lib.mkIf isNiri {
    wantedBy = [ "graphical.target" ];
    serviceConfig.ExecStartPost = pkgs.writeShellScript "power-profiles-default" ''
      if ! ${lib.getExe pkgs.gnugrep} -qs '^Profile=' /var/lib/power-profiles-daemon/state.ini; then
        ${lib.getExe config.services.power-profiles-daemon.package} set balanced
      fi
    '';
  };
}
