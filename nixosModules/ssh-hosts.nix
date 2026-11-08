{ config, ... }:
let
  inherit (config.oruc.machine) user;
  sshConfig = config.sops.secrets.ssh-config.path;
in
{
  sops.secrets.ssh-config = {
    sopsFile = ../secrets/workstations.yaml;
    owner = user;
  };

  home-manager.users.${user} =
    { config, ... }:
    {
      home.file.".ssh/config" = {
        source = config.lib.file.mkOutOfStoreSymlink sshConfig;
        force = true;
      };
    };
}
