# A machine nobody watches recovers on its own (features.alwaysOn). It never
# sleeps. A panic reboots it after 10 s and leaves its log in EFI pstore, which
# CachyOS's kernel turns off by default; systemd-pstore then moves the log to
# /var/lib/systemd/pstore. A hung system resets through the hardware watchdog
# when the platform provides one, and a failed mount after the initrd no longer
# stops at the emergency shell. The lid and power keys stay with each host.
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
