# Failure visibility on rog: disk health, a monthly scrub, and a desktop
# popup when a maintenance unit fails. systembus-notify turns a system D-Bus
# signal into a notification in the logged-in session. Any local user can
# send such a signal, and a signal sent while nobody is logged in is lost;
# the journal still has the failure.
{ lib, pkgs, ... }:
let
  # The unattended units whose failures would otherwise go unseen. Each must
  # stay enabled, or NixOS writes a unit with no ExecStart=, which systemd
  # refuses.
  watched = [
    "angrr"
    "nix-gc"
    "nix-optimise"
    "nixpkgs-clone"
    "oruc-cpu-limits"
    "oruc-low-battery"
    "smartd"
    "usque"
    # The template; the scrub of / runs as btrfs-scrub@-.service.
    "btrfs-scrub@"
  ];
in
{
  # The self-tests stay on latitude. nixpkgs runs the notifier, and with it
  # systembus-notify, only while a notification method such as the default
  # wall is on, so keep wall on.
  services.smartd.notifications.systembus-notify.enable = true;

  services.btrfs.autoScrub = {
    enable = true;
    interval = "monthly";
    fileSystems = [ "/" ];
  };
  # The popup names the unit without its instance (%p), because an instance
  # such as btrfs-scrub@-.service cannot be an instance name itself.
  systemd.services = lib.mkMerge [
    (lib.genAttrs watched (_: {
      onFailure = [ "notify-failure@%p.service" ];
    }))
    {
      # On battery the month's scrub is skipped, and the timer waits for the
      # next month.
      "btrfs-scrub@".unitConfig.ConditionACPower = true;
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
    }
  ];
}
