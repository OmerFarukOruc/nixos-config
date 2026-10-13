# Rootful Docker daemon with the compose v2 plugin. oruc uses the socket.
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
  };
  environment.systemPackages = [ pkgs.docker-compose ];
  users.users.oruc.extraGroups = [ "docker" ];
}
