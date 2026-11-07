{
  config,
  lib,
  pkgs,
  ...
}:
let
  guardrail = pkgs.writeShellApplication {
    name = "openrouter-free-guardrail";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.curl
      pkgs.jq
    ];
    text = builtins.readFile ./openrouter-free-guardrail.sh;
  };
  scheduledUnit = import ./scheduled-unit.nix { inherit config lib pkgs; };
in
{
  config = lib.mkMerge [
    { home.packages = [ guardrail ]; }
    (scheduledUnit {
      name = "openrouter-free-guardrail";
      description = "Refresh the OpenRouter guardrail's allowlist of free models";
      timerDescription = "Daily refresh of the OpenRouter free-model guardrail";
      execStart = lib.getExe guardrail;
      timeout = "1h";
      hint = "see journalctl --user -t openrouter-free-guardrail";
    })
  ];
}
