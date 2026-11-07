{ config, pkgs, ... }:
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
in
{
  home.packages = [ guardrail ];

  programs.zsh.initContent = ''
    if [[ -r ''${XDG_STATE_HOME:-$HOME/.local/state}/openrouter-free-guardrail/failed ]]; then
      print -r -- "openrouter-free-guardrail: $(<''${XDG_STATE_HOME:-$HOME/.local/state}/openrouter-free-guardrail/failed)"
    fi
  '';

  systemd.user.services.openrouter-free-guardrail = {
    Unit.Description = "Refresh the OpenRouter guardrail's allowlist of free models";
    Service = {
      Type = "oneshot";
      ExecStart = "%h/.local/bin/infisical-run.sh --env secrets --path /harness/openrouter-guardrail -- ${guardrail}/bin/openrouter-free-guardrail";
      Environment = [
        "PATH=/etc/profiles/per-user/${config.home.username}/bin:/run/current-system/sw/bin"
      ];
      TimeoutStartSec = "10min";
    };
  };
  systemd.user.timers.openrouter-free-guardrail = {
    Unit.Description = "Daily refresh of the OpenRouter free-model guardrail";
    Timer = {
      OnCalendar = "daily";
      Persistent = true;
      RandomizedDelaySec = "1h";
    };
    Install.WantedBy = [ "timers.target" ];
  };
}
