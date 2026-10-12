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
  # The daemon keeps the profile it finds at first start, which can be the
  # firmware's performance mode. It starts at boot rather than on the first
  # D-Bus call, and every boot starts in balanced. Use the shell's power menu
  # to change it for a session.
  systemd.services.power-profiles-daemon = lib.mkIf isNiri {
    wantedBy = [ "graphical.target" ];
    serviceConfig.ExecStartPost = "${lib.getExe config.services.power-profiles-daemon.package} set balanced";
  };
}
