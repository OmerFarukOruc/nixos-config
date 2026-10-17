# Every hour on AC power, scripts/auto-update.sh moves the flake inputs and the
# apps in pkgs/ that name a release source to their newest releases, deploys
# them to this host and merges them to main. The token is a systemd credential,
# and the script writes private runtime config files for gh and Nix. The token
# stays out of child-process environments; files remain readable by oruc.
#
# `upgrade` runs the updater now and shows its log while it runs.
{ config, pkgs, ... }:
let
  unit = "oruc-auto-update.service";
  identifier = "oruc-auto-update";
  upgrade = pkgs.writeShellApplication {
    name = "upgrade";
    text = ''
      # Asks for the password before the log starts, so the two do not share a line.
      sudo -v
      # The updater's output and systemd's start and end lines. --unit would
      # also show the session lines of every sudo call inside the run.
      journalctl --follow --lines 0 --output cat \
        _SYSTEMD_UNIT=${unit} SYSLOG_IDENTIFIER=${identifier} + _PID=1 UNIT=${unit} &
      follow=$!
      trap 'kill "$follow" 2>/dev/null' EXIT
      status=0
      # A oneshot start returns when the run ends, and joins a run the timer
      # already started. With a terminal on stdin, sudo runs the command in a
      # new pseudo-terminal and puts this terminal in raw mode, so each log
      # line printed meanwhile starts where the previous one ended.
      sudo systemctl start ${unit} </dev/null || status=$?
      # journalctl prints the last lines a moment after the unit ends.
      sleep 1
      if [[ $(systemctl show --property ConditionResult --value ${unit}) == no ]]; then
        echo "The updater runs only on AC power. Plug in and run upgrade again." >&2
        exit 1
      fi
      exit "$status"
    '';
  };
in
{
  environment.systemPackages = [ upgrade ];

  sops.secrets.github-update-token = { };
  # Its checkout and failure markers.
  oruc.keptPaths = [ "/var/lib/oruc-auto-update" ];

  systemd.services.oruc-auto-update = {
    description = "Update, deploy and merge the newest releases";
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];
    # The service runs the switch itself; restarting it then would kill
    # deploy.sh before it confirms the new system.
    restartIfChanged = false;
    unitConfig = {
      # A rollback to a system without this unit must not stop it mid-deploy.
      X-StopOnRemoval = false;
      ConditionACPower = true;
    };
    # NixOS adds coreutils, findutils, grep, sed and systemd to every service.
    # deploy.sh calls sudo, which lives in /run/wrappers/bin.
    path = [
      "/run/wrappers"
      config.nix.package
    ]
    ++ (with pkgs; [
      bash
      curl
      diffutils
      # The system diff in the PR body.
      dix
      gawk
      gh
      git
      jq
      libnotify
      python3
      rsync
      # flock for deploy.sh's lock.
      util-linux
    ]);
    serviceConfig = {
      Type = "oneshot";
      # Without a limit one hung network call keeps the unit active, and the
      # timer never starts it again. The longest run in the journal (24 runs
      # from 2026-10-10 to 2026-10-12) took 3 min 13 s; the rest is room for
      # compiling the packages of ci/cached-packages.nix when no cache holds
      # them. A kill sends the script SIGTERM, and its trap notifies. A kill
      # during deploy.sh leaves the rollback timer to restore the previous
      # system.
      TimeoutStartSec = "2h";
      User = "oruc";
      StateDirectory = "oruc-auto-update";
      RuntimeDirectory = "oruc-auto-update";
      RuntimeDirectoryMode = "0700";
      UMask = "0077";
      SyslogIdentifier = identifier;
      LoadCredential = "github-token:${config.sops.secrets.github-update-token.path}";
      ExecStart = "${pkgs.bash}/bin/bash ${../../scripts/auto-update.sh}";
    };
  };

  systemd.timers.oruc-auto-update = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "hourly";
      Persistent = true;
      RandomizedDelaySec = "10min";
    };
  };
}
