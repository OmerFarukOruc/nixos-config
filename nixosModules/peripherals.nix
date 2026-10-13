{
  config,
  lib,
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
  # The daemon starts at boot rather than on the first D-Bus call. It starts
  # in the profile last set, which it keeps in its state file, or in balanced
  # when the file holds none.
  systemd.services.power-profiles-daemon.wantedBy = lib.mkIf isNiri [ "graphical.target" ];
}
