# shellcheck shell=bash
PARALLEL_EACH_JOBS=${PARALLEL_EACH_JOBS:-2}
[[ $PARALLEL_EACH_JOBS =~ ^[1-9][0-9]*$ ]] || {
  echo "PARALLEL_EACH_JOBS must be a positive integer, not '$PARALLEL_EACH_JOBS'." >&2
  exit 2
}

parallel_each_stop() {
  local logs=$1 pids=("${@:2}")
  ((${#pids[@]} == 0)) || kill -TERM -- "${pids[@]/#/-}" 2>/dev/null
  wait
  cat "$logs"/* 2>/dev/null
  exit 130
}

parallel_each() {
  local - run=$1 arg pid n=0 status=0 logs
  local -A running=()
  shift
  logs=$(mktemp -d) || return 1
  set -m
  trap 'parallel_each_stop "$logs" "${!running[@]}"' INT TERM
  for arg in "$@"; do
    if ((${#running[@]} >= PARALLEL_EACH_JOBS)); then
      wait -n -p pid "${!running[@]}" || status=1
      cat "$logs/${running[$pid]}"
      unset "running[$pid]"
    fi
    "$run" "$arg" >"$logs/$n" 2>&1 &
    running[$!]=$n
    n=$((n + 1))
  done
  while ((${#running[@]})); do
    wait -n -p pid "${!running[@]}" || status=1
    cat "$logs/${running[$pid]}"
    unset "running[$pid]"
  done
  trap - INT TERM
  rm -rf -- "${logs:?}"
  return "$status"
}
