{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (config.oruc.upgrade) updater;

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
      sleep 1
      exit "$status"
    '';
  };

  deployMain = pkgs.writeShellApplication {
    name = "upgrade";
    runtimeInputs = with pkgs; [
      coreutils
      git
      gnugrep
      gnused
    ];
    text = ''
      replace=()
      if (($# == 1)) && [[ $1 == --replace ]]; then
        replace=(--replace)
      elif (($#)); then
        echo "usage: upgrade [--replace]" >&2
        exit 2
      fi
      if ((EUID == 0)); then
        echo "Run upgrade as your own user, because deploy.sh keeps its releases in that user's ~/.local/state." >&2
        exit 1
      fi
      host=$(</proc/sys/kernel/hostname)
      clone=$HOME/.local/state/nixos-config-upgrade
      if [[ ! -d $clone/.git ]]; then
        mkdir -p -- "$(dirname -- "$clone")"
        GIT_CONFIG_GLOBAL=/dev/null git clone --quiet https://github.com/OmerFarukOruc/nixos-config.git "$clone"
      fi
      cd "$clone"
      GIT_CONFIG_GLOBAL=/dev/null git fetch --quiet origin main
      git checkout --quiet --force --detach origin/main
      git clean -fdxq
      sha=$(git rev-parse HEAD)
      # shellcheck source=/dev/null
      . scripts/lib/running-revision.sh
      if runs_tree_of "$sha"; then
        echo "$host already runs main at ''${sha:0:12}."
        exit 0
      fi
      status=0
      ./deploy.sh "''${replace[@]}" "$host" switch || status=$?
      if ((status == 78)); then
        echo "Merge that work into main instead, or run upgrade --replace after its owner agrees." >&2
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
      echo "This host deploys only the main branch of nixos-config. Run upgrade as your own user to deploy it." >&2
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
  options.oruc.upgrade.updater = lib.mkOption {
    type = lib.types.nullOr lib.types.str;
    default = null;
    example = "oruc-auto-update";
    description = "Base name of the systemd unit that `upgrade` starts instead of deploying main itself. With null, `upgrade` deploys the newest main to this host.";
  };

  config = {
    system.tools.nixos-rebuild.enable = false;
    environment.systemPackages = [
      (if updater == null then deployMain else runUpdater)
      rollbackOnlyRebuild
    ];
  };
}
