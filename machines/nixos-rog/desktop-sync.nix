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
  # The checkout's pre-commit hook installs ruff and shellcheck through mise at
  # the versions the checkout pins, for commits typed in a shell too.
  home.packages = [
    pkgs.python3
    pkgs.mise
  ];

  systemd.user.services.desktop-sync-config = {
    Unit = {
      Description = "Omer's desktop-sync, config only";
      ConditionPathExists = "${dotfiles}/desktop/bin/desktop-sync.sh";
    };
    Service = {
      Type = "oneshot";
      ExecStart = "${dotfiles}/desktop/bin/desktop-sync.sh --config";
      WorkingDirectory = dotfiles;
      # The pre-commit hook falls back to this ruff and shellcheck when mise
      # cannot download the pinned versions.
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
