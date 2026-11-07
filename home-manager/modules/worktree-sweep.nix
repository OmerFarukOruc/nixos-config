{
  config,
  lib,
  pkgs,
  ...
}:
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
  dailyUnit = import ./daily-unit.nix { inherit config lib pkgs; };
in
{
  config = lib.mkMerge [
    { home.packages = [ sweep ]; }
    (dailyUnit {
      name = "worktree-sweep";
      description = "Remove merged, clean worktrees under ~/Desktop/workspace";
      timerDescription = "Daily sweep of merged worktrees";
      execStart = "${sweep}/bin/worktree-sweep";
      timeout = "30min";
      hint = "see /tmp/agents/worktree-sweep/report.md and journalctl --user -t worktree-sweep";
      stopPost = [ "${pkgs.coreutils}/bin/rm -f /tmp/agents/worktree-sweep/.report.draft" ];
    })
  ];
}
