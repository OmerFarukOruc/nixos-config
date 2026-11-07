{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.oruc.agents;
  pull = pkgs.writeShellApplication {
    name = "agents-pull";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.curl
      pkgs.git
    ];
    text = builtins.readFile ./agents-pull.sh;
  };
  scheduledUnit = import ./scheduled-unit.nix { inherit config lib pkgs; };
in
{
  options.oruc.agents.checkout = lib.mkOption {
    type = lib.types.str;
    default = "${config.home.homeDirectory}/Desktop/workspace/nixos-config";
    description = "The nixos-config main checkout whose agents/ folder the agent CLIs read live (agents/README.md).";
  };

  config = lib.mkMerge [
    { home.packages = [ pull ]; }
    (scheduledUnit {
      name = "agents-pull";
      description = "Pull nixos-config main into the checkout that agents/ is read from";
      timerDescription = "Hourly pull of the nixos-config checkout";
      execStart = "${lib.getExe pull} ${lib.escapeShellArg cfg.checkout}";
      timeout = "10min";
      hint = "see journalctl --user -t agents-pull";
      onCalendar = "hourly";
      randomizedDelay = "10min";
    })
  ];
}
