# Containers without root: Docker through RootlessKit and Podman with its user
# socket, both for oruc (the subuid and subgid ranges are in the host's user
# record). oruc is in no docker group; each daemon answers on a socket in
# $XDG_RUNTIME_DIR.
_: {
  # RootlessKit 3, because 2.x lets the kernel kill dockerd after connections to
  # a published port (overlays/rootlesskit.nix).
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
    # DOCKER_HOST for oruc's shells; the socket is $XDG_RUNTIME_DIR/docker.sock.
    setSocketVariable = true;
    # The build cache cap that the Debian box has used, with no measurement
    # behind it.
    daemon.settings.builder.gc = {
      enabled = true;
      defaultMaxUsedSpace = "80GB";
    };
  };

  # Podman has no daemon; podman.socket (a user unit that the module wants at
  # sockets.target) starts `podman system service` for each client of
  # $XDG_RUNTIME_DIR/podman/podman.sock. cliproxy's compose file reaches it with
  # DOCKER_HOST and the docker CLI.
  virtualisation.podman.enable = true;
}
