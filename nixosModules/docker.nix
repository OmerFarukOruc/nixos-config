{
  config,
  lib,
  pkgs,
  ...
}:
lib.mkIf config.oruc.machine.features.docker {
  virtualisation.docker = {
    enable = true;
    autoPrune = {
      enable = true;
      dates = "weekly";
    };
    daemon.settings = {
      builder.gc = {
        enabled = true;
        defaultMaxUsedSpace = "80GB";
      };
      ip = "127.0.0.1";
      default-network-opts.bridge."com.docker.network.bridge.host_binding_ipv4" = "127.0.0.1";
    };
  };
  # Interfaces made after boot, such as Docker's veths and bridges, get no IPv6
  # link-local address. Each such address that appears or goes makes Brave and
  # other Chromium browsers abort open requests with ERR_NETWORK_CHANGED.
  # NetworkManager sets the mode itself on the interfaces it manages, so those
  # keep their link-local address.
  boot.kernel.sysctl."net.ipv6.conf.default.addr_gen_mode" = 1;
  environment.systemPackages = [ pkgs.docker-compose ];
  users.users.${config.oruc.machine.user}.extraGroups = [ "docker" ];
}
