# Wi-Fi driver option, TCP tuning and the Tailscale operator.
_: {
  # Disabling ASPM keeps the MT7925 from dropping its link, as on CachyOS.
  # Wi-Fi is the only way in, so this stays until a test without it passes.
  boot.extraModprobeConfig = ''
    options mt7925e disable_aspm=Y
  '';

  # browser-lend runs `tailscale serve` as oruc to lend Brave's debugging port
  # to risoluto-dev-1, and only the operator may change serve without sudo.
  # The list adds to the shared flags in nixosModules/connectivity.nix.
  services.tailscale.extraSetFlags = [ "--operator=oruc" ];

  boot.kernel.sysctl = {
    # Congestion control only shapes what this laptop sends.
    "net.ipv4.tcp_congestion_control" = "bbr";
    # Attaches to tailscale0 and wired links; Wi-Fi keeps mac80211's own queue.
    "net.core.default_qdisc" = "fq";
    # Room for QUIC receive and send buffers.
    "net.core.rmem_max" = 16777216;
    "net.core.wmem_max" = 16777216;
    "net.ipv4.tcp_slow_start_after_idle" = 0;
    # Recovers from paths that drop ICMP "fragmentation needed".
    "net.ipv4.tcp_mtu_probing" = 1;
  };
}
