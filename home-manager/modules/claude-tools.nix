{
  config,
  lib,
  pkgs,
  ...
}:
let
  claudeTools = pkgs.callPackage ../../pkgs/claude-tools.nix { };
  accounts = "${config.home.homeDirectory}/Desktop/workspace/dotfiles/desktop/claude-code/accounts.json";
in
{
  home.packages = [
    claudeTools
    pkgs.gum
    pkgs.jq
    pkgs.openssh
    pkgs.python3
    pkgs.tmux
  ];

  programs.zsh.initContent = lib.mkOrder 1500 ''
    . ${claudeTools}/share/claude-tools/claude-tools.sh
  '';

  oruc.plasma.claudeAccountsWidget = true;

  systemd.user.services.claude-tools-usage = {
    Unit = {
      Description = "Read the usage limits and login state of every Claude Code account";
      ConditionPathExists = accounts;
    };
    Service = {
      Type = "oneshot";
      ExecStart = "${claudeTools}/bin/claude-tools usage --quiet";
      Environment = [
        "PATH=${config.home.homeDirectory}/.local/bin:/etc/profiles/per-user/${config.home.username}/bin:/run/current-system/sw/bin"
      ];
      TimeoutStartSec = "15min";
    };
  };
  systemd.user.timers.claude-tools-usage = {
    Unit.Description = "Read Claude Code account usage every 10 minutes";
    Timer = {
      OnCalendar = "*:0/10";
      RandomizedDelaySec = "30s";
      OnStartupSec = "1min";
    };
    Install.WantedBy = [ "timers.target" ];
  };
}
