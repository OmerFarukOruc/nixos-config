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
  # The battery widgets of the desktop shells read UPower. Plasma turns it on
  # without a battery too, because its power management needs it.
  services.upower.enable = lib.mkDefault cfg.hasBattery;

  # Plasma's battery applet and the niri shells' power menus switch profiles
  # through this daemon. On a host without a firmware platform profile
  # (/sys/firmware/acpi/platform_profile) a profile changes only the CPU's
  # energy preference (EPP) and boost.
  services.power-profiles-daemon.enable = true;
  # The daemon starts at boot rather than on the first D-Bus call. It starts
  # in the profile last set, which it keeps in its state file, or in balanced
  # when the file holds none.
  systemd.services.power-profiles-daemon.wantedBy = [ "graphical.target" ];
}
