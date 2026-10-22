# Every hour the dotfiles checkout's desktop-sync.sh links the agent config
# (Claude Code and Codex rules, skills, hooks, agents) into place and syncs
# Claude Code's settings.json both ways, as desktop-sync-config.timer does on
# fedora-desktop. On a NixOS host it leaves the shell and tools to Home Manager.
# The checkout's claude-usage keeps ~/.cache/claude-usage/usage.json fresh for
# the Claude accounts widget, which desktop-sync.sh links into place.
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
  oruc.plasma.claudeAccountsWidget = true;

  # Reads every Claude Code account's usage limits and login state, and the
  # logins on the hosts that remote_hosts in the checkout's accounts.json names
  # over SSH, through the gcr agent in the user manager's environment.
  systemd.user.services.claude-usage = {
    Unit = {
      Description = "Read the usage limits and login state of every Claude Code account";
      ConditionPathExists = "${dotfiles}/desktop/bin/claude-usage";
    };
    Service = {
      Type = "oneshot";
      ExecStart = "${dotfiles}/desktop/bin/claude-usage --quiet";
      # claude is in ~/.local/bin; each account whose access token expired
      # runs a one-turn claude -p, up to 90 s each.
      Environment = [
        "PATH=${config.home.homeDirectory}/.local/bin:/etc/profiles/per-user/${config.home.username}/bin:/run/current-system/sw/bin"
      ];
      TimeoutStartSec = "15min";
    };
  };
  systemd.user.timers.claude-usage = {
    # Every 10 minutes, a guess that keeps the usage endpoint's request rate
    # low.
    Unit.Description = "Read Claude Code account usage every 10 minutes";
    Timer = {
      OnCalendar = "*:0/10";
      RandomizedDelaySec = "30s";
      # Without it, the widget can show no data for up to 10 minutes after
      # a login.
      OnStartupSec = "1min";
    };
    Install.WantedBy = [ "timers.target" ];
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
