{
  config,
  lib,
  pkgs,
  sessions,
  ...
}:
let
  memoryPressureSnapshot = pkgs.writers.writePython3Bin "memory-pressure-snapshot" { } (
    builtins.readFile ./memory-pressure-snapshot.py
  );
in
{
  systemd.oomd.enableUserSlices = true;

  systemd.slices.user.sliceConfig.ManagedOOMSwap = lib.mkDefault "kill";

  systemd.user.units."app-ghostty-surface-transient-.scope" =
    lib.mkIf (sessions.hasAnyDesktop config.oruc.machine)
      {
        overrideStrategy = "asDropin";
        text = ''
          [Scope]
          TasksMax=4096
          MemoryMax=20G
          MemorySwapMax=6G
        '';
      };

  systemd.user.services.memory-pressure-snapshot = {
    description = "Write a process snapshot when memory pressure rises";
    wantedBy = [ "default.target" ];
    serviceConfig = {
      ExecStart = "${memoryPressureSnapshot}/bin/memory-pressure-snapshot";
      Restart = "on-failure";
      RestartSec = 10;
      MemoryMax = "128M";
      MemorySwapMax = 0;
    };
  };

  systemd.user.settings.Manager.DefaultOOMPolicy = "continue";

  boot = lib.mkIf config.zramSwap.enable {
    kernelParams = [ "zswap.enabled=0" ];
    kernel.sysctl = {
      "vm.swappiness" = lib.mkDefault 150;
      "vm.page-cluster" = 0;
    };
  };
}
