# Failure visibility: disk health, a monthly scrub of a btrfs root, and a
# desktop popup when a maintenance unit fails. smartd watches every disk and
# logs to the journal. With features.diskSelfTests it also runs a short
# self-test daily at 02:00 and a long one on Sundays at 03:00.
# systembus-notify turns a system D-Bus signal into a notification in the
# logged-in session. Any local user can send such a signal, and a signal sent
# while nobody is logged in is lost; the journal still has the failure. A
# machine with no desktop session gets neither the notifier nor the popup.
{
  config,
  lib,
  pkgs,
  sessions,
  ...
}:
let
  desktop = sessions.hasAnyDesktop config.oruc.machine;
  scrub = config.fileSystems."/".fsType == "btrfs";
  # The unattended units whose failures would otherwise go unseen. Each must
  # stay enabled, or NixOS writes a unit with no ExecStart=, which systemd
  # refuses. A host file adds its own units with the same onFailure.
  watched = [
    "angrr"
    "nix-gc"
    "nix-optimise"
    "smartd"
  ]
  # The template; the scrub of / runs as btrfs-scrub@-.service.
  ++ lib.optional scrub "btrfs-scrub@";
in
{
  services.smartd = {
    enable = true;
    autodetect = true;
    defaults.autodetected = lib.mkIf config.oruc.machine.features.diskSelfTests "-a -o on -S on -s (S/../.././02|L/../../7/03)";
    # nixpkgs runs the notifier, and with it systembus-notify, only while a
    # notification method such as the default wall is on, so keep wall on.
    notifications.systembus-notify.enable = desktop;
  };

  services.btrfs.autoScrub = lib.mkIf scrub {
    enable = true;
    interval = "monthly";
    fileSystems = [ "/" ];
  };
  # The popup names the unit without its instance (%p), because an instance
  # such as btrfs-scrub@-.service cannot be an instance name itself.
  systemd.services = lib.mkMerge [
    (lib.mkIf desktop (
      lib.genAttrs watched (_: {
        onFailure = [ "notify-failure@%p.service" ];
      })
    ))
    (lib.mkIf scrub {
      # On battery the month's scrub is skipped, and the timer waits for the
      # next month. A host without a battery always meets the condition.
      "btrfs-scrub@".unitConfig.ConditionACPower = true;
    })
    (lib.mkIf desktop {
      "notify-failure@" = {
        description = "Desktop popup for the failed unit %i";
        serviceConfig = {
          Type = "oneshot";
          # escapeSystemdExecArgs would double the % and stop %i expanding.
          ExecStart = lib.escapeShellArgs [
            "${pkgs.dbus}/bin/dbus-send"
            "--system"
            "/"
            "net.nuetzlich.SystemNotifications.Notify"
            "string:%i failed"
            "string:See: journalctl -b -u '%i*'"
          ];
        };
      };
    })
  ];
}
