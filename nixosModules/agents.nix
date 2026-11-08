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
    claude-tools-accounts = {
      sopsFile = ../secrets/agents.yaml;
      owner = user;
    };
    agents-linear-notes = {
      sopsFile = ../secrets/agents.yaml;
      owner = user;
    };
  };

  environment.etc."grok/managed_config.toml".source = ../agents/grok/managed_config.toml;

  home-manager.users.${user}.imports = [ ../home-manager/modules/agents.nix ];
}
