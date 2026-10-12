{ config, lib, ... }:
{
  # systemd-oomd monitors no cgroup until a slice opts in. When memory pressure
  # in a user slice stays above 80% for 30 s, it kills every process in one
  # leaf cgroup under it, such as an app's scope or one Konsole tab.
  systemd.oomd.enableUserSlices = true;

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
