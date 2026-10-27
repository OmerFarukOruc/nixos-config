# The sshd settings of every host that runs it (connectivity.nix for a
# workstation, server-access.nix for a server). The firewall stays closed to
# sshd's port, and tailscale.nix trusts only tailscale0, so only the tailnet
# reaches it.
{ config, lib, ... }:
lib.mkIf config.services.openssh.enable {
  services.openssh = {
    openFirewall = false;
    settings = {
      AuthenticationMethods = "publickey";
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      # A client that stopped answering for 45 s loses its session, which frees
      # the deploy lock it held.
      ClientAliveInterval = 15;
      ClientAliveCountMax = 3;
    };
  };
}
