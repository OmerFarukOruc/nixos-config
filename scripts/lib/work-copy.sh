# shellcheck shell=bash disable=SC2119,SC2120 # callers pass copy_run its ARGs
# shellcheck source=/dev/null
. scripts/lib/rog-host.sh
COPY_SSH=(ssh -o BatchMode=yes -o ConnectTimeout=15)
# A local run starts without the caller's Git variables, as an SSH login does.
# A git hook exports GIT_DIR and GIT_INDEX_FILE, and with them the copy's
# git add would write to the caller's index.
COPY_LOCAL_ENV=(env -u GIT_DIR -u GIT_INDEX_FILE -u GIT_WORK_TREE -u GIT_COMMON_DIR)
COPY_DIR=
COPY_CHILD=
COPY_PARENT=
COPY_PID_FILE=
COPY_CALLS=0

# copy_wait CMD [ARG...]: runs CMD, the local Nix run or the ssh client, and
# waits for it. A TERM, INT, QUIT or HUP that reaches the script, even one
# sent to its PID alone, as `kill PID` does, runs copy_stop before the EXIT
# trap removes the copy. Without this, `kill PID` left Nix running. CMD runs
# in the background so that bash runs the trap during `wait`; for a foreground
# command bash would hold the trap until CMD ended. CMD stays in the script's
# process group, so Ctrl-Z and a SIGKILL to the group reach it as they would
# in the foreground. As a background command CMD ignores INT and QUIT, so
# Ctrl-C and Ctrl-\ stop it through the trap.
copy_wait() {
  local rc=0
  trap 'copy_stop 143' TERM
  trap 'copy_stop 130' INT
  trap 'copy_stop 131' QUIT
  trap 'copy_stop 129' HUP
  # Bash gives a background command /dev/null as stdin unless it names one.
  "$@" <&0 &
  COPY_CHILD=$! COPY_PARENT=$BASHPID
  wait "$COPY_CHILD" || rc=$?
  trap - TERM INT QUIT HUP
  COPY_CHILD=
  return "$rc"
}

copy_stat() {
  local stat
  read -r stat 2>/dev/null <"/proc/$1/stat" || return 1
  COPY_STAT=${stat##*) }
}

copy_alive() {
  copy_stat "$1" && [[ ${COPY_STAT%% *} != Z ]]
}

copy_tree() {
  local child
  copy_alive "$1" || return 0
  echo "$1"
  for child in $(ps -o pid= --ppid "$1"); do
    copy_tree "$child"
  done
}

# copy_cgroup: prints COPY_CHILD's cgroup when it differs from its parent's, as
# under heavy's scope, and nothing otherwise. Bash may have reaped the command
# already, and then its PID can belong to another process, so with COPY_PARENT
# set the PID counts only while its parent is the shell that started it.
copy_cgroup() {
  local parent child ppid
  copy_stat "$COPY_CHILD" || return 0
  read -r _ ppid _ <<<"$COPY_STAT"
  [[ -z $COPY_PARENT || $ppid == "$COPY_PARENT" ]] || return 0
  parent=$(cat "/proc/$ppid/cgroup" 2>/dev/null) || return 0
  child=$(cat "/proc/$COPY_CHILD/cgroup" 2>/dev/null) || return 0
  [[ $child == "$parent" ]] || echo "${child#0::}"
}

copy_procs() {
  local cgroup=$1 pid
  shift
  if [[ -n $cgroup ]]; then
    cat "/sys/fs/cgroup$cgroup/cgroup.procs" 2>/dev/null || true
    return 0
  fi
  {
    copy_tree "$COPY_CHILD"
    for pid in "$@"; do
      if copy_alive "$pid"; then echo "$pid"; fi
    done
  } | sort -u
}

COPY_STOP_STEP=0.1
# A guess: Nix printed "interrupted by the user" and ended within 44 ms of TERM
# on 2026-10-24, so 50 steps, about 5 s, leave it a wide margin.
COPY_STOP_STEPS=50
copy_stop_child() {
  local cgroup='' pids=() step
  for ((step = 0; step < COPY_STOP_STEPS; step++)); do
    [[ -n $cgroup ]] || cgroup=$(copy_cgroup)
    mapfile -t pids < <(copy_procs "$cgroup" "${pids[@]}")
    ((${#pids[@]})) || break
    kill -s TERM "${pids[@]}" 2>/dev/null || true
    read -rt "$COPY_STOP_STEP" <> <(:) || true
  done
  if ((${#pids[@]})) && ! { [[ -n $cgroup ]] && echo 1 >"/sys/fs/cgroup$cgroup/cgroup.kill"; } 2>/dev/null; then
    kill -s KILL "${pids[@]}" 2>/dev/null || true
  fi
}

copy_stop_remote() {
  {
    declare -f copy_stat copy_alive copy_tree copy_cgroup copy_procs copy_stop_child
    declare -p COPY_STOP_STEP COPY_STOP_STEPS COPY_PID_FILE
    cat <<'REMOTE'
COPY_CHILD= COPY_PARENT=
for ((step = 0; step < COPY_STOP_STEPS; step++)); do
  read -r COPY_CHILD 2>/dev/null <"$COPY_PID_FILE" && break
  read -rt "$COPY_STOP_STEP" <> <(:) || true
done
if [[ -n $COPY_CHILD ]] && tr '\0' '\n' <"/proc/$COPY_CHILD/cmdline" 2>/dev/null | grep -qF -- "$1"; then
  copy_stop_child
fi
REMOTE
  } | timeout -s KILL "$COPY_STOP_SSH_SECONDS" "${COPY_SSH[@]}" "$ROG_HOST" \
    "bash -s -- $(printf %q "$COPY_DIR")" || true
}
# The stop ignores further signals, so a connection that stalls after it
# opened must not hold it: ConnectTimeout in COPY_SSH bounds only the connect.
# 30 s, a guess, covers that 15 s, twice COPY_STOP_STEPS steps on the host and
# a margin.
COPY_STOP_SSH_SECONDS=30

copy_stop() {
  trap '' TERM INT QUIT HUP
  if [[ -n $COPY_CHILD ]]; then
    if [[ -n $COPY_PID_FILE ]]; then copy_stop_remote; fi
    copy_stop_child
    wait "$COPY_CHILD" 2>/dev/null || true
    COPY_CHILD=
  fi
  trap - TERM INT QUIT HUP
  exit "$1"
}

# copy_run [ARG...] < SCRIPT: runs SCRIPT on the host in bash, with the
# copy's path as $1 and each ARG after it. The host's login shell is zsh, so
# the arguments go through printf %q. Data goes to the host in its own call,
# never beside a script, because the script already uses the call's stdin: bash
# drops a piped input and zsh merges it into the script.
#
# copy_run runs under heavy when the host has it (home-manager/modules/heavy.nix),
# so each Nix call gets its own memory cap. copy_run_light runs without it,
# for a call that runs no Nix.
copy_run() {
  local args rc=0
  if ((ROG_LOCAL)); then
    if command -v heavy >/dev/null; then
      copy_wait "${COPY_LOCAL_ENV[@]}" heavy bash -s -- "$COPY_DIR" "$@"
    else
      copy_wait "${COPY_LOCAL_ENV[@]}" bash -s -- "$COPY_DIR" "$@"
    fi
    return
  fi
  args=$(printf '%q ' "$COPY_DIR" "$@")
  COPY_PID_FILE=$COPY_DIR/.git/copy-pid.$((++COPY_CALLS))
  copy_wait "${COPY_SSH[@]}" "$ROG_HOST" "echo \$\$ >$(printf %q "$COPY_PID_FILE"); if command -v heavy >/dev/null; then exec heavy bash -s -- $args; else exec bash -s -- $args; fi" || rc=$?
  COPY_PID_FILE=
  return "$rc"
}

copy_run_light() {
  if ((ROG_LOCAL)); then
    copy_wait "${COPY_LOCAL_ENV[@]}" bash -s -- "$COPY_DIR" "$@"
    return
  fi
  "${COPY_SSH[@]}" "$ROG_HOST" "bash -s -- $(printf '%q ' "$COPY_DIR" "$@")"
}

copy_path() {
  if ((ROG_LOCAL)); then
    printf '%s/' "$COPY_DIR"
  else
    printf '%s:%s/' "$ROG_HOST" "$COPY_DIR"
  fi
}

copy_open() {
  case ${1:-} in
    --on-rog) rog_pick_host ;;
    "")
      if ! command -v nix >/dev/null; then
        echo "$0 runs Nix on this host, and nix is not on PATH." >&2
        exit 1
      fi
      ROG_LOCAL=1
      ;;
    *)
      echo "copy_open: unknown option $1" >&2
      exit 2
      ;;
  esac
  if ((ROG_LOCAL)); then
    COPY_DIR=$(mktemp -d /tmp/check-nixos-config.XXXXXXXX)
  else
    COPY_DIR=$("${COPY_SSH[@]}" "$ROG_HOST" mktemp -d /tmp/check-nixos-config.XXXXXXXX)
  fi
  if [[ ! $COPY_DIR =~ ^/tmp/check-nixos-config\.[A-Za-z0-9]{8}$ ]]; then
    echo "mktemp printed an unexpected path: $COPY_DIR" >&2
    exit 1
  fi
  # shellcheck disable=SC2016 # the remote bash expands $1
  trap 'copy_run_light <<<"rm -rf -- \"\$1\"" || true' EXIT

  git ls-files -co --exclude-standard -z |
    rsync -a --from0 --ignore-missing-args --files-from=- ./ "$(copy_path)"
  # A git flake, like a checkout. Without git add, Nix would leave the new
  # files out of it.
  copy_run_light <<'REMOTE'
set -e
cd "$1"
git init -q
git add -A
REMOTE
}
