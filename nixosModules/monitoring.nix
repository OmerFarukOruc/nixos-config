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
in
{
  options.oruc.failurePopupUnits = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [ ];
    example = [ "case-fans" ];
    description = ''
      Systemd services that raise the desktop failure popup when they fail,
      named without the `.service` suffix. A module that defines a long-running
      or timer-run service on a desktop host adds its name here. The popup
      exists only on a machine with a login session, and every name needs an
      ExecStart= or a script on that machine.
    '';
  };

  config = {
    oruc.failurePopupUnits = [
      "angrr"
      "nix-gc"
      "nix-optimise"
      "smartd"
    ]
    ++ lib.optional scrub "btrfs-scrub@";

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
          message = "${name} notifies on failure but has no ExecStart=; turn its module on or drop it from oruc.failurePopupUnits.";
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
        lib.genAttrs (lib.unique config.oruc.failurePopupUnits) (_: {
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
  };
}
