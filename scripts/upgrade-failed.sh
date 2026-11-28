#!/usr/bin/env bash
# usage: nixos-upgrade-failed
# Runs as OnFailure= of nixos-upgrade.service. The first failure of a revision of main records it in retry, so the
# next hourly run tries it again. A second failure, or a failure of a revision already marked failed, marks it in
# failed, which the hourly runs skip until main moves, then shows a popup when POPUP_HOST is set and runs
# INSTALL_REPORT failed when that is set. Reads MONITOR_SERVICE_RESULT from systemd's OnFailure= run.
set -euo pipefail

state=/var/lib/nixos-upgrade

if [[ ${MONITOR_SERVICE_RESULT:-} == signal ]]; then
  echo "nixos-upgrade was stopped by a signal, so main is not recorded as failed"
  exit 0
fi
if [[ ! -f $state/candidate ]]; then
  echo "nixos-upgrade failed before it chose a revision of main, so nothing is recorded"
  exit 0
fi
candidate=$(<"$state/candidate")

marked() {
  [[ -f $state/$1 && $(<"$state/$1") == "$candidate" ]]
}

if ! marked failed && ! marked retry; then
  echo "$candidate" >"$state/retry"
  echo "Installing main at ${candidate:0:12} failed once, so the next hourly run tries it again before it is marked as failed"
  exit 0
fi
echo "$candidate" >"$state/failed"
echo "Installing main at ${candidate:0:12} failed again, so it is marked as failed until main moves"

if [[ -n ${POPUP_HOST:-} ]]; then
  dbus-send --system / net.nuetzlich.SystemNotifications.Notify \
    "string:Update failed" \
    "string:$POPUP_HOST could not install main at ${candidate:0:12} and keeps its system until main moves. See: journalctl -u nixos-upgrade" ||
    echo "The Update failed popup could not be sent"
fi
if [[ -n ${INSTALL_REPORT:-} ]]; then
  timeout 120 "$INSTALL_REPORT" failed || echo "install-report: no answer from GitHub within 120 s"
fi
