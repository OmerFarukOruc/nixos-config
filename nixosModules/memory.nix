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
  # systemd-oomd monitors no cgroup until a slice opts in. When memory pressure
  # in a slice of the user manager stays above 80% for 30 s, it kills every
  # process in one leaf cgroup under it, such as an app's scope or one Ghostty
  # tab. oomd honors ManagedOOMPreference=avoid on a user's cgroup only when a
  # cgroup that user owns is the monitored one (systemd.resource-control(5)),
  # so the root-owned user.slice stays unmonitored and herdr's avoid counts.
  systemd.oomd.enableUserSlices = true;
  systemd.slices.user.sliceConfig.ManagedOOMMemoryPressure = lib.mkForce "auto";

  # With swap and memory both above 90%, oomd kills the leaf cgroup with the
  # most swap under app.slice: a Ghostty tab, Brave or a build scope. herdr's
  # agents run in session.slice (home-manager/modules/herdr.nix), out of reach.
  systemd.user.units."app.slice" = lib.mkIf (sessions.hasAnyDesktop config.oruc.machine) {
    overrideStrategy = "asDropin";
    text = ''
      [Slice]
      ManagedOOMSwap=kill
    '';
  };

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
      # Swapped out, the service would fault back in at the moment pressure
      # peaks, and systemd-oomd's swap kill above would rank it as a candidate.
      MemorySwapMax = 0;
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
      "vm.swappiness" = lib.mkDefault 150;
      # Read one page per swap-in; readahead buys nothing on zram.
      "vm.page-cluster" = 0;
    };
  };
}
