{ config, lib, ... }:
lib.mkIf config.oruc.machine.features.lavdScheduler {
  nixpkgs.overlays = [ (import ../overlays/scx-loader.nix) ];
  services.scx-loader = {
    enable = true;
    config = {
      default_sched = "scx_lavd";
      default_mode = "Gaming";
      scheds.scx_lavd.gaming_mode = [ "--performance" ];
    };
  };
  # scx_loader starts scx_lavd as its child, which inherits the scheduling
  # settings. The loader exits when the scheduler exits (overlays/scx-loader.nix),
  # so Restart and the start limit cover both.
  systemd.services.scx_loader = {
    unitConfig.ConditionPathIsDirectory = "/sys/kernel/sched_ext";
    startLimitIntervalSec = 30;
    startLimitBurst = 2;
    serviceConfig = {
      CPUSchedulingPolicy = "fifo";
      CPUSchedulingPriority = 99;
      IOSchedulingClass = "realtime";
      Restart = "always";
      RestartSec = 3;
    };
  };
}
