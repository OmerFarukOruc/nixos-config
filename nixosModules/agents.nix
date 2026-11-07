{ config, ... }:
let
  inherit (config.oruc.machine) user;
in
{
  sops.secrets = {
    agents-private-values = {
      sopsFile = ../secrets/agents.yaml;
      owner = user;
    };
    agents-infisical-ids = {
      sopsFile = ../secrets/agents.yaml;
      owner = user;
    };
  };

  home-manager.users.${user}.imports = [ ../home-manager/modules/agents.nix ];
}
