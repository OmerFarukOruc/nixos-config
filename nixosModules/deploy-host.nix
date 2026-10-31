{ config, lib, ... }:
let
  cfg = config.oruc.deploy;
in
{
  options.oruc.deploy.sessionIgnore = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [ ];
    example = [ "herdr-*.service" ];
    description = "Shell globs of the user services that deploy.sh's session check ignores, such as long-running agents that a switch may restart.";
  };

  config = lib.mkIf (cfg.sessionIgnore != [ ]) {
    environment.etc."nixos-config-deploy/session-ignore".text = lib.concatLines cfg.sessionIgnore;
  };
}
