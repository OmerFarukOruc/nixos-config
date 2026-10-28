_: {
  nixpkgs.overlays = [ (import ../overlays/rootlesskit.nix) ];

  # Rootless Docker picks the host port of a published container from the
  # ip_local_port_range of RootlessKit's network namespace, which is the kernel
  # default 32768-60999 (Documentation/networking/ip-sysctl.rst), and RootlessKit
  # then binds that port on the host, where an outbound connection may already
  # hold it. The host's own outbound connections take their ports from the range
  # below, which does not overlap. 61000-65535 is 4535 ports per destination
  # address and port (65535 - 61000 + 1); that this suffices for the agents'
  # outbound connections is a guess (`ss -Htn state established | wc -l` on the
  # Debian box printed 15 on 2026-10-27).
  boot.kernel.sysctl."net.ipv4.ip_local_port_range" = "61000 65535";

  virtualisation.docker.rootless = {
    enable = true;
    setSocketVariable = true;
    daemon.settings.builder.gc = {
      enabled = true;
      defaultMaxUsedSpace = "80GB";
    };
  };

  virtualisation.podman.enable = true;
}
