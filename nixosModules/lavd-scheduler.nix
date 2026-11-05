{ config, lib, ... }:
lib.mkIf config.oruc.machine.features.lavdScheduler {
  services.scx = {
    enable = true;
    scheduler = "scx_lavd";
    extraArgs = [ "--performance" ];
  };
  # The scheduler's daemon must run when the CPUs are saturated, and comes
  # back after a crash. A crash loop still hits the unit's start limit of 2
  # starts in 30 s and leaves it failed. RT throttling is off on this kernel,
  # so a spinning daemon would hold a CPU.
  systemd.services.scx.serviceConfig = {
    CPUSchedulingPolicy = "fifo";
    CPUSchedulingPriority = 99;
    IOSchedulingClass = "realtime";
    Restart = lib.mkForce "always";
    RestartSec = 3;
  };
}
