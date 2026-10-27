# `upgrade` brings this host to the newest main. On a host that sets
# oruc.upgrade.updater it starts that unit and shows its log while it runs, so
# a run never races the unit's timer. On every other
# host it deploys the newest main to this host with deploy.sh, from a clone that
# only upgrade uses (docs/deploy.md, Upgrade a host to main).
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
      # The unit's ConditionACPower skips a run on battery, and systemctl start
      # still exits 0.
      if ! ${config.systemd.package}/bin/systemd-ac-power; then
        echo "The deploy runs only on AC power. Plug in and run upgrade again." >&2
        exit 1
      fi
      # Asks for the password before the log starts, so the two do not share a line.
      sudo -v
      # The unit's output and systemd's start and end lines. --unit would
      # also show the session lines of every sudo call inside the run.
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
      # journalctl prints the last lines a moment after the unit ends.
      sleep 1
      exit "$status"
    '';
  };

  # deploy.sh comes from the clone and finds its own tools, such as nix, dix,
  # rsync and sudo, on the system path, which runtimeInputs only prepends to.
  deployMain = pkgs.writeShellApplication {
    name = "upgrade";
    runtimeInputs = with pkgs; [
      coreutils
      git
      gnugrep
      gnused
    ];
    text = ''
      # --replace passes on to deploy.sh, which then drops the files of a running
      # release from another checkout (docs/deploy.md, Dirty trees and other
      # checkouts).
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
      # Beside deploy.sh's releases, which ignore XDG_STATE_HOME too.
      clone=$HOME/.local/state/nixos-config-upgrade
      # The personal Git config hands github.com credentials to gh, which may
      # have no login on this host. The repository is public and needs none.
      if [[ ! -d $clone/.git ]]; then
        mkdir -p -- "$(dirname -- "$clone")"
        GIT_CONFIG_GLOBAL=/dev/null git clone --quiet https://github.com/OmerFarukOruc/nixos-config.git "$clone"
      fi
      cd "$clone"
      GIT_CONFIG_GLOBAL=/dev/null git fetch --quiet origin main
      # The clone belongs to upgrade. The reset also drops the flake.lock that
      # deploy.sh copied back after the last deploy.
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
      # deploy.sh's own advice names this clone, which the next run resets.
      if ((status == 78)); then
        echo "Merge that work into main instead, or run upgrade --replace after its owner agrees." >&2
      fi
      exit "$status"
    '';
  };
in
{
  options.oruc.upgrade.updater = lib.mkOption {
    type = lib.types.nullOr lib.types.str;
    default = null;
    example = "oruc-auto-update";
    description = "Base name of the systemd unit that `upgrade` starts instead of deploying main itself. With null, `upgrade` deploys the newest main to this host.";
  };

  config.environment.systemPackages = [ (if updater == null then deployMain else runUpdater) ];
}
