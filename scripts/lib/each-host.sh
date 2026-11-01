# shellcheck shell=bash
EACH_HOST_JOBS=2

each_host() {
  local run=$1 host pid status=0
  local -A running=()
  shift
  for host in "$@"; do
    if ((${#running[@]} >= EACH_HOST_JOBS)); then
      wait -n -p pid "${!running[@]}" || status=1
      unset "running[$pid]"
    fi
    "$run" "$host" &
    running[$!]=$host
  done
  while ((${#running[@]})); do
    wait -n -p pid "${!running[@]}" || status=1
    unset "running[$pid]"
  done
  return "$status"
}
