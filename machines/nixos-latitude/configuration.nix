_:

{
  nix = {
    daemonCPUSchedPolicy = "idle";
    daemonIOSchedClass = "idle";
  };

  services.logind.settings.Login = {
    HandleLidSwitch = "ignore";
    HandleLidSwitchExternalPower = "ignore";
    HandleLidSwitchDocked = "ignore";
    HandlePowerKey = "ignore";
  };

  oruc.autoUpgrade.enable = true;

  home-manager.users.oruc.imports = [ ./home.nix ];

  zramSwap = {
    enable = true;
    memoryPercent = 50;
  };

  system.stateVersion = "26.11";
}
