_: {
  # Disabling ASPM keeps the MT7925 from dropping its link, as on CachyOS.
  # Wi-Fi is the only way in, so this stays until a test without it passes.
  boot.extraModprobeConfig = ''
    options mt7925e disable_aspm=Y
  '';

  # browser-lend runs `tailscale serve` as oruc to lend Brave's debugging port
  # to devbox, and only the operator may change serve without sudo.
  # The list adds to the shared flags in nixosModules/connectivity.nix.
  services.tailscale.extraSetFlags = [ "--operator=oruc" ];

  boot.kernel.sysctl = {
    "net.ipv4.tcp_congestion_control" = "bbr";
    "net.core.default_qdisc" = "fq";
    "net.core.rmem_max" = 16777216;
    "net.core.wmem_max" = 16777216;
    "net.ipv4.tcp_slow_start_after_idle" = 0;
    "net.ipv4.tcp_mtu_probing" = 1;
  };
}
