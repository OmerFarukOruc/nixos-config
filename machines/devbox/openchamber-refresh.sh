#!/usr/bin/env bash
usage="usage: openchamber-refresh OPENCHAMBER_PACKAGE OPENCHAMBER_PORT"
package=${1:?$usage}
chamber_port=${2:?$usage}
unit=openchamber.service
policy=/etc/openchamber/policy.json

fail() {
  echo "openchamber-refresh: $*" >&2
  exit 1
}

store_dir() {
  [[ -e $1 ]] || fail "$1 does not exist"
  readlink -e "$1" | cut -d/ -f1-4
}

unit_procs() {
  local cgroup
  cgroup=$(systemctl --user show "$unit" -p ControlGroup --value)
  [[ -n $cgroup ]] || fail "$unit has no control group"
  cat "/sys/fs/cgroup$cgroup/cgroup.procs"
}

opencode_get() {
  curl -fsS -m 10 --variable '%OPENCODE_SERVER_PASSWORD' \
    --expand-user 'opencode:{{OPENCODE_SERVER_PASSWORD}}' "http://127.0.0.1:$opencode_port$1"
}

main=$(systemctl --user show "$unit" -p MainPID --value)
if [[ $main == 0 ]]; then
  echo "$unit is not running."
  exit 0
fi

health=$(curl -fsS -m 10 "http://127.0.0.1:$chamber_port/health")
if ! opencode_port=$(jq -re 'select(.openCodeRunning == true) | .openCodePort | numbers' <<<"$health"); then
  echo "Waiting, because OpenChamber reports its OpenCode server as not ready."
  exit 0
fi
info=$(opencode_get /api/info)
opencode_pid=$(jq -re '.pid | numbers' <<<"$info") || fail "OpenCode's /api/info has no pid: $info"
procs=$(unit_procs)
grep -qx "$opencode_pid" <<<"$procs" ||
  fail "OpenCode (pid $opencode_pid) runs outside $unit, such as OpenCode's shared service, so restarting $unit would not update it"

stale=()
cmdline=$(tr '\0' ' ' <"/proc/$main/cmdline")
if [[ $cmdline != *"$package/"* ]]; then
  stale+=("OpenChamber $(jq -r .openchamberVersion <<<"$health") runs instead of ${package##*-}")
fi
running=$(store_dir "/proc/$opencode_pid/exe")
wanted=$(store_dir "$(jq -re '.opencodeBinary | strings' "$policy")")
if [[ $running != "$wanted" ]]; then
  stale+=("OpenCode $(jq -r .version <<<"$info") runs from $running instead of $wanted")
fi

if ((${#stale[@]} == 0)); then
  echo "OpenChamber and its OpenCode run the installed versions."
  exit 0
fi
printf -v reason '%s; ' "${stale[@]}"

active=$(opencode_get /api/session/active)
sessions=$(jq -re '.data | objects | length' <<<"$active") ||
  fail "OpenCode's /api/session/active has no session list: $active"
procs=$(unit_procs)
ttys=$(ps -o tty= -p "$(paste -sd, <<<"$procs")" | tr -d ' ')
terminals=$(grep -c -v -x '?' <<<"$ttys" || true)

if ((sessions > 0 || terminals > 0)); then
  echo "${reason}waiting, because $sessions OpenCode sessions and $terminals terminal processes run."
  exit 0
fi
systemctl --user restart "$unit"
echo "${reason}restarted $unit."
