{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (config.oruc.upgrade) updater nowFile;

  runUpdater = pkgs.writeShellApplication {
    name = "upgrade";
    runtimeInputs = with pkgs; [
      gnused
      jq
    ];
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
      cursor=$(journalctl --show-cursor --lines 0 --no-pager | sed -n 's/^-- cursor: //p')
      ${lib.optionalString (nowFile != null) "sudo touch ${lib.escapeShellArg nowFile}"}
      journalctl --follow --after-cursor "$cursor" --output cat \
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
      skipped=$(journalctl --after-cursor "$cursor" --output json --no-pager \
        _PID=1 UNIT="$unit" UNIT_RESULT=exec-condition | jq -r '.INVOCATION_ID' | tail -n 1)
      if [[ -n $skipped ]]; then
        reason=$(journalctl --output cat --no-pager _SYSTEMD_INVOCATION_ID="$skipped" SYSLOG_IDENTIFIER="$identifier" | tail -n 1)
        echo "The run skipped: ''${reason:-no reason logged}" >&2
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
