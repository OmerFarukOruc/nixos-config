{ config, lib, ... }:
{
  # systemd-oomd monitors no cgroup until a slice opts in. When memory pressure
  # in a user slice stays above 80% for 30 s, it kills every process in one
  # leaf cgroup under it, such as an app's scope or one Konsole tab.
  systemd.oomd.enableUserSlices = true;

  # zram swaps fast enough that memory pressure can stay under that limit
  # while swap fills, and then the kernel OOM killer picks the biggest single
  # process. On 2026-10-24 a tab with thousands of small python3 processes
  # filled RAM and swap twice, and the kernel killed Ghostty's main process,
  # which closed every tab. With swap and memory both above 90%, this kills the
  # leaf cgroup with the most swap instead, such as that one tab
  # (systemd-oomd.service(8), oomd.conf(5) SwapUsedLimit=).
  systemd.slices.user.sliceConfig.ManagedOOMSwap = "kill";

  # Each Ghostty tab is a transient scope, and this drop-in matches every
  # one by its name prefix. The limits keep a fork loop or a leak inside one
  # tab. On 2026-10-24 the busiest normal tab peaked at 2494 tasks, 16.2 GiB
  # of RAM and 1.7 GiB of swap, and the runaway tab at 18.9 GiB of RAM and
  # 23.8 GiB of swap. MemoryMax alone would have missed it, so swap has its own
  # cap. The values sit above the normal peaks; they are not measured limits.
  systemd.user.units."app-ghostty-surface-transient-.scope" = {
    overrideStrategy = "asDropin";
    text = ''
      [Scope]
      TasksMax=4096
      MemoryMax=20G
      MemorySwapMax=6G
    '';
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
