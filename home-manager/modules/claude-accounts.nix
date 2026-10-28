# Omer's Claude Code accounts on this machine (pkgs/claude-tools.nix): `claude`
# rotates between them and `claude --account NAME` pins one, claude-accounts
# manages them, and claude-usage keeps ~/.cache/claude-usage/usage.json fresh
# for claude-rotate, claude-limit-switch and the Claude accounts widget.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  claudeTools = pkgs.callPackage ../../pkgs/claude-tools.nix { };
in
{
  # The tools run jq, gum (the account table), tmux and ssh (logins and usage
  # on another host); the Python ones run under the package's own python3.
  home.packages = [
    claudeTools
    pkgs.gum
    pkgs.jq
    pkgs.openssh
    pkgs.tmux
  ];

  # The completion for claude-accounts needs compinit, which runs earlier.
  programs.zsh.initContent = lib.mkOrder 1500 ''
    . ${claudeTools}/share/claude-tools/claude-accounts.sh
  '';

  oruc.plasma.claudeAccountsWidget = true;

  # Reads every account's usage limits and login state, and the logins on the
  # hosts that remote_hosts in accounts.json names over SSH, through the gcr
  # agent in the user manager's environment.
  systemd.user.services.claude-usage = {
    Unit.Description = "Read the usage limits and login state of every Claude Code account";
    Service = {
      Type = "oneshot";
      ExecStart = "${claudeTools}/bin/claude-usage --quiet";
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
}
