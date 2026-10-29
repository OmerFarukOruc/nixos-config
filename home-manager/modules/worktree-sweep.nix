{ config, pkgs, ... }:
let
  sweep = pkgs.writeShellApplication {
    name = "worktree-sweep";
    runtimeInputs = [
      config.programs.worktrunk.package
      pkgs.coreutils
      pkgs.git
      pkgs.jq
    ];
    text = builtins.readFile ./worktree-sweep.sh;
  };
in
{
  home.packages = [ sweep ];

  programs.zsh.initContent = ''
    if [[ -r ''${XDG_STATE_HOME:-$HOME/.local/state}/worktree-sweep/failed ]]; then
      print -r -- "worktree-sweep: $(<''${XDG_STATE_HOME:-$HOME/.local/state}/worktree-sweep/failed)"
    fi
  '';

  systemd.user.services.worktree-sweep = {
    Unit.Description = "Remove merged, clean worktrees under ~/Desktop/workspace";
    Service = {
      Type = "oneshot";
      ExecStart = "${sweep}/bin/worktree-sweep";
      Environment = [
        "PATH=/etc/profiles/per-user/${config.home.username}/bin:/run/current-system/sw/bin"
      ];
      TimeoutStartSec = "30min";
    };
  };
  systemd.user.timers.worktree-sweep = {
    Unit.Description = "Daily sweep of merged worktrees";
    Timer = {
      OnCalendar = "daily";
      Persistent = true;
      RandomizedDelaySec = "1h";
    };
    Install.WantedBy = [ "timers.target" ];
  };
}
