# Mission Center's extra values. Its fan readings need nothing, because hwmon
# fan inputs are world-readable.
{ pkgs, ... }:
{
  # CPU power draw reads the RAPL energy counter, which the kernel keeps
  # root-only because power readings leak data across processes
  # (CVE-2020-8694). Only wheel may read it here.
  services.udev.extraRules = ''
    SUBSYSTEM=="powercap", KERNEL=="intel-rapl:*", RUN+="${pkgs.coreutils}/bin/chgrp wheel /sys%p/energy_uj", RUN+="${pkgs.coreutils}/bin/chmod g+r /sys%p/energy_uj"
  '';

  # Per-process network usage comes from nethogs, found through PATH, which
  # needs packet capture and access to other processes' sockets.
  security.wrappers.nethogs = {
    source = "${pkgs.nethogs}/bin/nethogs";
    owner = "root";
    group = "wheel";
    permissions = "u+rx,g+rx";
    capabilities = "cap_net_admin,cap_net_raw,cap_dac_read_search,cap_sys_ptrace+ep";
  };
}
