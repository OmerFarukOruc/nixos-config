# Every hour the dotfiles checkout's desktop-sync.sh links the agent config
# (Claude Code and Codex rules, skills, hooks, agents) into place and syncs
# Claude Code's settings.json both ways. It leaves the shell and tools to Home
# Manager; the Claude account tools come from claude-accounts.nix.
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
  imports = [ ./claude-accounts.nix ];

  # json-config.py and the Claude Code hooks in settings.json run under
  # python3, and desktop-sync.sh runs jq. The checkout's
  # pre-commit hook installs ruff and shellcheck through mise at the versions
  # the checkout pins, for commits typed in a shell too. The checkout's
  # sandbox-run, which the shared agent rules require for a probe of a kill or
  # rm command, runs bwrap.
  home.packages = [
    pkgs.bubblewrap
    pkgs.python3
    pkgs.mise
    pkgs.jq
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
      # cannot download the pinned versions. ~/.local/bin holds mise, which
      # the run calls.
      Environment = [
        "PATH=${
          lib.makeBinPath [
            pkgs.ruff
            pkgs.shellcheck
          ]
        }:${config.home.homeDirectory}/.local/bin:/etc/profiles/per-user/${config.home.username}/bin:/run/current-system/sw/bin"
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
