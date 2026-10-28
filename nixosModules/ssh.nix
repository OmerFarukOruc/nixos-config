{ config, lib, ... }:
lib.mkIf config.services.openssh.enable {
  services.openssh = {
    openFirewall = false;
    settings = {
      AuthenticationMethods = "publickey";
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      ClientAliveInterval = 15;
      ClientAliveCountMax = 3;
    };
  };
}
