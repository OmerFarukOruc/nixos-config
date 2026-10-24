{
  config,
  lib,
  pkgs,
  ...
}:
let
  memoryPressureSnapshot = pkgs.writers.writePython3Bin "memory-pressure-snapshot" { } (
    builtins.readFile ./memory-pressure-snapshot.py
  );
in
{
  # systemd-oomd monitors no cgroup until a slice opts in. When memory pressure
  # in a user slice stays above 80% for 30 s, it kills every process in one
  # leaf cgroup under it, such as an app's scope or one Ghostty tab.
  systemd.oomd.enableUserSlices = true;

  # On 2026-10-24 a tab with about 6400 small python3 processes filled RAM and
  # swap twice. systemd-oomd did not act on memory pressure, the kernel OOM
  # killer picked the biggest single process instead, and that was Ghostty's
  # main process, which closed every tab. With swap and memory both above 90%,
  # this makes systemd-oomd kill the leaf cgroup with the most swap, such as
  # that one tab (systemd-oomd.service(8), oomd.conf(5) SwapUsedLimit=).
  systemd.slices.user.sliceConfig.ManagedOOMSwap = "kill";

  # Each Ghostty tab is a transient scope, and this drop-in matches every
  # one by its name prefix. The limits keep a fork loop or a leak inside one
  # tab. On 2026-10-24 the busiest normal tab peaked at 2494 tasks, 16.2 GiB
  # of RAM and 1.7 GiB of swap, and the runaway tab at 18.9 GiB of RAM and
  # 23.8 GiB of swap. MemoryMax alone would have missed it, so swap has its own
  # cap. The values sit above the normal peaks; they are not measured limits.
  # The busiest normal tab runs herdr and its agents, so it is the one closest
  # to the limits; when it passes 20G the kernel kills its largest process.
  systemd.user.units."app-ghostty-surface-transient-.scope" = {
    overrideStrategy = "asDropin";
    text = ''
      [Scope]
      TasksMax=4096
      MemoryMax=20G
      MemorySwapMax=6G
    '';
  };

  # The kernel's OOM task table names no parent and no command line, and the
  # processes are gone by the time anyone looks. This service writes every
  # process with its parent and command line, and each user cgroup's memory,
  # to ~/.local/state/oom-snapshots/ when memory pressure rises, so the last
  # snapshot before an OOM kill shows what spawned the memory.
  systemd.user.services.memory-pressure-snapshot = {
    description = "Write a process snapshot when memory pressure rises";
    wantedBy = [ "default.target" ];
    serviceConfig = {
      ExecStart = "${memoryPressureSnapshot}/bin/memory-pressure-snapshot";
      Restart = "on-failure";
      RestartSec = 10;
      # A guess that keeps the service itself small under the pressure it
      # watches; one snapshot of 474 processes took 36 KB.
      MemoryMax = "128M";
    };
  };

  # When the kernel OOM killer kills one process of a user unit, systemd stops
  # the whole unit by default (DefaultOOMPolicy=stop in systemd-user.conf(5)).
  # A terminal tab or a browser is one scope, so losing a test run or a
  # renderer would close the tab or the whole browser. Keep the rest running.
  systemd.user.settings.Manager.DefaultOOMPolicy = "continue";

  boot = lib.mkIf config.zramSwap.enable {
    # The CachyOS kernels turn zswap on by default, which compresses a page
    # once in zswap and again on its way to zram.
    kernelParams = [ "zswap.enabled=0" ];
    kernel.sysctl = {
      # zram reads back faster than the SSD, so swap before dropping page cache
      # (Documentation/admin-guide/sysctl/vm.rst, swappiness).
      "vm.swappiness" = 150;
      # Read one page per swap-in; readahead buys nothing on zram.
      "vm.page-cluster" = 0;
    };
  };
}
