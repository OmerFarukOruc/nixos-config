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
  watched = [
    "angrr"
    "nix-gc"
    "nix-optimise"
    "smartd"
  ]
  ++ lib.optional scrub "btrfs-scrub@";
in
{
  services.smartd = {
    enable = lib.mkDefault true;
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

  assertions =
    lib.mapAttrsToList
      (name: service: {
        assertion = service.enable && (service.script != "" || service.serviceConfig ? ExecStart);
        message = "${name} notifies on failure but has no ExecStart=; turn its module on or drop it from the watched units.";
      })
      (
        lib.filterAttrs (
          _: service: lib.elem "notify-failure@%p.service" service.onFailure
        ) config.systemd.services
      );
  # The popup names the unit without its instance (%p), because an instance
  # such as btrfs-scrub@-.service cannot be an instance name itself.
  systemd.services = lib.mkMerge [
    (lib.mkIf desktop (
      lib.genAttrs watched (_: {
        onFailure = [ "notify-failure@%p.service" ];
      })
    ))
    (lib.mkIf scrub {
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
