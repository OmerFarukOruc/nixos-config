{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (config.oruc.upgrade) updater nowFile;
  systemctl = "${config.systemd.package}/bin/systemctl";

  runUpdater = pkgs.writeShellApplication {
    name = "upgrade";
    text = ''
      unit=${updater}.service
      identifier=${updater}
      if (($#)); then
        echo "usage: upgrade" >&2
        exit 2
      fi
      if ! ${config.systemd.package}/bin/systemd-ac-power; then
        echo "The deploy runs only on AC power. Plug in and run upgrade again." >&2
        exit 1
      fi
      sudo -v
      joined=false
      case $(${systemctl} show -P ActiveState "$unit") in
        activating | active | deactivating | reloading) joined=true ;;
      esac
      started=$(${systemctl} show -P ExecMainStartTimestampMonotonic "$unit")
      ${lib.optionalString (nowFile != null) "sudo touch ${lib.escapeShellArg nowFile}"}
      journalctl --follow --lines 0 --output cat \
        _SYSTEMD_UNIT="$unit" SYSLOG_IDENTIFIER="$identifier" + _PID=1 UNIT="$unit" &
      follow=$!
      trap 'kill "$follow" 2>/dev/null' EXIT
      status=0
      # A oneshot start returns when the run ends, and joins a run the timer
      # already started. With a terminal on stdin, sudo runs the command in a
      # new pseudo-terminal and puts this terminal in raw mode, so each log
      # line printed meanwhile starts where the previous one ended.
      sudo systemctl start "$unit" </dev/null || status=$?
      ${lib.optionalString (nowFile != null) "sudo rm -f ${lib.escapeShellArg nowFile}"}
      sleep 1
      if ((status == 0)) && ! $joined && [[ $(${systemctl} show -P ExecMainStartTimestampMonotonic "$unit") == "$started" ]]; then
        echo "The run skipped; the line above says why." >&2
        exit 1
      fi
      exit "$status"
    '';
  };

  stockRebuild = config.system.build.nixos-rebuild;

  rollbackOnlyRebuildBin = pkgs.writeShellApplication {
    name = "nixos-rebuild";
    text = ''
      rebuild=${stockRebuild}/bin/nixos-rebuild
      case "''${1-}" in
        list-generations | --help | -h)
          exec "$rebuild" "$@"
          ;;
        switch | boot | test)
          for arg in "''${@:2}"; do
            if [[ $arg == --rollback ]]; then
              exec "$rebuild" "$@" --no-reexec
            fi
          done
          ;;
      esac
      echo "This host deploys only the main branch of nixos-config. Run upgrade to install it." >&2
      echo "nixos-rebuild here runs only switch --rollback, boot --rollback, test --rollback, list-generations and --help." >&2
      exit 1
    '';
  };

  rollbackOnlyRebuild = pkgs.symlinkJoin {
    name = "nixos-rebuild";
    paths = [ rollbackOnlyRebuildBin ];
    postBuild = "ln -s ${stockRebuild}/share $out/share";
  };
in
{
  options.oruc.upgrade.nowFile = lib.mkOption {
    type = lib.types.nullOr lib.types.str;
    default = null;
    example = "/var/lib/nixos-upgrade/now";
    description = "A file that `upgrade` creates before it starts the updater, so that run skips the checks that only defer it.";
  };

  options.oruc.upgrade.updater = lib.mkOption {
    type = lib.types.nullOr lib.types.str;
    default = null;
    example = "nixos-upgrade";
    description = "Base name of the systemd unit that `upgrade` starts to install the newest main. With null, the host has no `upgrade`.";
  };

  config = {
    system.tools.nixos-rebuild.enable = false;
    environment.systemPackages = [ rollbackOnlyRebuild ] ++ lib.optional (updater != null) runUpdater;
  };
}
