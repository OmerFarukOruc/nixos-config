# Dell Latitude 3550. Role and login sessions: machines/inventory.nix.
# Hardware facts and measured dead ends: docs/nixos-latitude.md.
_:

{
  nix = {
    daemonCPUSchedPolicy = "idle";
    daemonIOSchedClass = "idle";
  };

  # Lab box: never sleep. The lid and the power key do nothing.
  services.logind.settings.Login = {
    HandleLidSwitch = "ignore";
    HandleLidSwitchExternalPower = "ignore";
    HandleLidSwitchDocked = "ignore";
    HandlePowerKey = "ignore";
  };
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

  # A lab box nobody watches recovers on its own. A panic reboots it after
  # 10 s and leaves its log in EFI pstore, which CachyOS's kernel turns off by
  # default; systemd-pstore then moves the log to /var/lib/systemd/pstore. A
  # hung system resets through the hardware watchdog when the platform provides
  # one, and a failed mount after the initrd no longer stops at the emergency
  # shell.
  boot.kernelParams = [
    "panic=10"
    "efi_pstore.pstore_disable=0"
  ];
  systemd.settings.Manager = {
    RuntimeWatchdogSec = "20s";
    RebootWatchdogSec = "30s";
  };
  systemd.enableEmergencyMode = false;

  home-manager.users.oruc.imports = [ ./home.nix ];

  users.users.oruc.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMV6Kg6JIDEOFDbA5ezTsHnxFq2fXzB75x0+tybHlB/h omer-all-devices"
  ];

  # Compressed swap in RAM. No swap partition, no swap file.
  zramSwap = {
    enable = true;
    memoryPercent = 50;
  };

  system.stateVersion = "26.11";
}
