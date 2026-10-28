# The Grok bots log in as a user over OpenSSH on tailnet port 2222
# (server-access.nix) with one key, and this module writes that key as the only
# line of the user's authorized_keys, limited to the bots' machine with `from=`. The limit is the
# machine's current tailnet IPv4 address, which the machine gets anew each
# time it logs in to the tailnet, so a timer reads it every 5 minutes with
# `tailscale ip -4` and rewrites the line when it changed. A tag or a range
# would not do: the bots' machine holds a Tailscale OAuth client that can join
# any machine under the bots' tag, and any machine that joined that way would
# pass a rule that checks only the tag. The address is a run-time value and
# stays out of this public repository.
#
# A machine that logs in while its old node is still registered comes back as
# NAME-1. With a credential, fleet-bots-ts-name (a Tailscale OAuth client with
# devices write) gives the online node its name back and renames the offline
# ones, and prints the address of the node it renamed. Without one, the pin
# still follows the address that tailscaled reports for the name.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.oruc.fleetBots;
  account = config.users.users.${cfg.user};
  keys = "${account.home}/.ssh/authorized_keys";

  pin = pkgs.writeShellApplication {
    name = "fleet-bots-pin";
    # The script finds tailscale and fleet-bots-ts-name on the unit's path.
    text = builtins.readFile ./fleet-bots-pin.sh;
  };
  renamer = pkgs.writers.writePython3Bin "fleet-bots-ts-name" {
    # The script keeps the long lines of its docstring and its messages.
    flakeIgnore = [ "E501" ];
  } (builtins.readFile ./fleet-bots-ts-name.py);
in
{
  options.oruc.fleetBots = {
    enable = lib.mkEnableOption "the timer that pins the bots' key to the current tailnet address of their machine";
    user = lib.mkOption {
      type = lib.types.str;
      description = "The account the bots log in as. Its authorized_keys holds only the pinned line, and the timer rewrites the file.";
    };
    peer = lib.mkOption {
      type = lib.types.str;
      example = "bots-host";
      description = "Tailnet name of the bots' machine.";
    };
    tag = lib.mkOption {
      type = lib.types.str;
      example = "tag:bots";
      description = "Tailscale tag of the bots' machine. The rename touches only devices that carry it.";
    };
    publicKeyFile = lib.mkOption {
      type = lib.types.path;
      description = "A file with the bots' SSH public key on one line.";
    };
    credentialFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      example = "/run/secrets/fleet-bots-ts-client";
      description = "A file with TS_OAUTH_CLIENT_ID= and TS_OAUTH_CLIENT_SECRET= lines for a Tailscale OAuth client with devices:core write. Without it the rename is skipped and the pin still runs.";
    };
  };

  config = lib.mkIf cfg.enable {
    # ProtectSystem=strict below needs the directory, and sshd's StrictModes
    # refuses a home directory that others can write to.
    systemd.tmpfiles.rules = [ "d ${account.home}/.ssh 0700 ${cfg.user} ${account.group} -" ];

    systemd.services.fleet-bots-pin = {
      description = "Pin ${cfg.user}'s bot key to the current tailnet address of ${cfg.peer}";
      wants = [ "tailscaled.service" ];
      after = [ "tailscaled.service" ];
      path = [
        config.services.tailscale.package
        renamer
      ];
      serviceConfig = {
        Type = "oneshot";
        # The unit runs as root and reads the credential file itself. A
        # LoadCredential= entry would fail the unit when the file is missing,
        # and the pin must run without it.
        ExecStart = lib.escapeShellArgs (
          [
            (lib.getExe pin)
            cfg.user
            keys
            cfg.peer
            cfg.tag
            cfg.publicKeyFile
          ]
          ++ lib.optional (cfg.credentialFile != null) cfg.credentialFile
        );
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ReadWritePaths = [ "${account.home}/.ssh" ];
        PrivateTmp = true;
        TimeoutStartSec = "2min";
      };
    };

    systemd.timers.fleet-bots-pin = {
      description = "Re-pin ${cfg.user}'s bot key every 5 minutes";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "2min";
        OnUnitActiveSec = "5min";
      };
    };

    oruc.telemetry = {
      journalUnits = [ "fleet-bots-pin.service" ];
      # The timer starts the unit every 5 minutes, which is 2 audit records for
      # each run and 576 a day. A SigNoz count on the Debian host over 11 to 12
      # October 2026 found 586 of them among 76,271 audit records (infra
      # docs/runners/measurements.md), and none carried information.
      auditDropUnits = [ "fleet-bots-pin" ];
    };
  };
}
