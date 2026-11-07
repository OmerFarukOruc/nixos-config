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
  imports = [ ./claude-tools.nix ];

  home.packages = [
    pkgs.mise
    pkgs.jq
  ];

  systemd.user.services.desktop-sync = {
    Unit = {
      Description = "Omer's desktop-sync";
      ConditionPathExists = "${dotfiles}/desktop/bin/desktop-sync.sh";
    };
    Service = {
      Type = "oneshot";
      ExecStart = "${dotfiles}/desktop/bin/desktop-sync.sh";
      WorkingDirectory = dotfiles;
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
  systemd.user.timers.desktop-sync = {
    Unit.Description = "Hourly desktop-sync for Omer's user";
    Timer = {
      OnCalendar = "hourly";
      Persistent = true;
      RandomizedDelaySec = "10min";
    };
    Install.WantedBy = [ "timers.target" ];
  };
}
