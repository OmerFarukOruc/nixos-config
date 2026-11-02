# shellcheck shell=bash
PARALLEL_EACH_JOBS=${PARALLEL_EACH_JOBS:-2}
[[ $PARALLEL_EACH_JOBS =~ ^[1-9][0-9]*$ ]] || {
  echo "PARALLEL_EACH_JOBS must be a positive integer, not '$PARALLEL_EACH_JOBS'." >&2
  exit 2
}

parallel_each_stop() {
  local pids=("$@")
  ((${#pids[@]} == 0)) || kill -TERM -- "${pids[@]/#/-}" 2>/dev/null
  wait
  exit 130
}

parallel_each() {
  local - run=$1 arg pid status=0
  local -A running=()
  shift
  set -m
  trap 'parallel_each_stop "${!running[@]}"' INT TERM
  for arg in "$@"; do
    if ((${#running[@]} >= PARALLEL_EACH_JOBS)); then
      wait -n -p pid "${!running[@]}" || status=1
      unset "running[$pid]"
    fi
    "$run" "$arg" &
    running[$!]=$arg
  done
  while ((${#running[@]})); do
    wait -n -p pid "${!running[@]}" || status=1
    unset "running[$pid]"
  done
  trap - INT TERM
  return "$status"
}
