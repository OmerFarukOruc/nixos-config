# Dell Latitude 3550. Role and login sessions: machines/inventory.nix.
# Hardware facts and measured dead ends: docs/nixos-latitude.md.
_:

{
  nix = {
    daemonCPUSchedPolicy = "idle";
    daemonIOSchedClass = "idle";
  };

  # Lab box: the lid and the power key do nothing. features.alwaysOn keeps it
  # awake and recovers it (nixosModules/always-on.nix).
  services.logind.settings.Login = {
    HandleLidSwitch = "ignore";
    HandleLidSwitchExternalPower = "ignore";
    HandleLidSwitchDocked = "ignore";
    HandlePowerKey = "ignore";
  };

  home-manager.users.oruc.imports = [ ./home.nix ];

  # Compressed swap in RAM. No swap partition, no swap file.
  zramSwap = {
    enable = true;
    memoryPercent = 50;
  };

  system.stateVersion = "26.11";
}
