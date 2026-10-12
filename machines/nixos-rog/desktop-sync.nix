# Every hour the dotfiles checkout's desktop-sync.sh links the agent config
# (Claude Code and Codex rules, skills, hooks, agents) into place and syncs
# Claude Code's settings.json both ways, as desktop-sync-config.timer does on
# fedora-desktop. On this host it leaves the shell and tools to Home Manager.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  dotfiles = "${config.home.homeDirectory}/Desktop/workspace/dotfiles";
in
{
  # json-config.py and the Claude Code hooks in settings.json run under python3.
  home.packages = [ pkgs.python3 ];

  systemd.user.services.desktop-sync-config = {
    Unit = {
      Description = "Omer's desktop-sync, config only";
      ConditionPathExists = "${dotfiles}/desktop/bin/desktop-sync.sh";
    };
    Service = {
      Type = "oneshot";
      ExecStart = "${dotfiles}/desktop/bin/desktop-sync.sh --config";
      WorkingDirectory = dotfiles;
      # ruff and shellcheck run the checkout's pre-commit hook when a run
      # commits recorded config.
      Environment = [
        "PATH=${
          lib.makeBinPath [
            pkgs.ruff
            pkgs.shellcheck
          ]
        }:/etc/profiles/per-user/${config.home.username}/bin:/run/current-system/sw/bin"
        "DESKTOP_SYNC_COMMIT=1"
      ];
      TimeoutStartSec = "10min";
    };
  };
  systemd.user.timers.desktop-sync-config = {
    Unit.Description = "Hourly config-only desktop-sync for Omer's user";
    Timer = {
      OnCalendar = "hourly";
      Persistent = true;
      RandomizedDelaySec = "10min";
    };
    Install.WantedBy = [ "timers.target" ];
  };
}
