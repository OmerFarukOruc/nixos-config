{ config, lib, ... }:
lib.mkIf config.oruc.machine.features.alwaysOn {
  systemd.sleep.settings.Sleep = {
    AllowSuspend = "no";
    AllowHibernation = "no";
    AllowHybridSleep = "no";
    AllowSuspendThenHibernate = "no";
  };
  systemd.targets.sleep.enable = false;
  systemd.targets.suspend.enable = false;
  systemd.targets.hibernate.enable = false;
  systemd.targets.hybrid-sleep.enable = false;

  boot.kernelParams = [
    "panic=10"
    "efi_pstore.pstore_disable=0"
  ];
  systemd.settings.Manager = {
    RuntimeWatchdogSec = "20s";
    RebootWatchdogSec = "30s";
  };
  systemd.enableEmergencyMode = false;
}
