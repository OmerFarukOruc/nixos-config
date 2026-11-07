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
  dailyUnit = import ./daily-unit.nix { inherit config lib pkgs; };
in
{
  config = lib.mkMerge [
    { home.packages = [ guardrail ]; }
    (dailyUnit {
      name = "openrouter-free-guardrail";
      description = "Refresh the OpenRouter guardrail's allowlist of free models";
      timerDescription = "Daily refresh of the OpenRouter free-model guardrail";
      execStart = "%h/.local/bin/infisical-run.sh --env secrets --path /harness/openrouter-guardrail -- ${guardrail}/bin/openrouter-free-guardrail";
      timeout = "1h";
      hint = "see journalctl --user -u openrouter-free-guardrail";
    })
  ];
}
