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
    # The Apple vendor ID. AirPods open their control channel, which
    # airpods-tui (home-manager/modules/airpods.nix) speaks, only to a host
    # that reported it when they paired.
    settings.General.DeviceID = "bluetooth:004C:0000:0000";
  };
  services.blueman.enable = isNiri;

  services.udisks2.enable = true;
  services.upower.enable = lib.mkDefault cfg.hasBattery;

  services.power-profiles-daemon.enable = true;
  systemd.services.power-profiles-daemon.wantedBy = [ "graphical.target" ];
}
