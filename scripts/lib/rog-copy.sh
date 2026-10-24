# shellcheck shell=bash disable=SC2119,SC2120 # callers pass rog_remote its ARGs
# Sourced by the scripts that run Nix on a copy of this checkout (build-on-rog.sh,
# check-on-rog.sh, eval-on-rog.sh, run-unit-on-rog.sh) after they cd to the
# checkout's root. They work on a copy on nixos-rog from either host, or on
# this host when scripts/lib/rog-host.sh picks it, as when nixos-rog is
# offline. The copy holds the tracked files and the new files that .gitignore
# does not exclude, as they are in the working tree.
# shellcheck source=/dev/null
. scripts/lib/rog-host.sh
ROG_SSH=(ssh -o BatchMode=yes -o ConnectTimeout=15)
# A local run starts without the caller's Git variables, as an SSH login does.
# A git hook exports GIT_DIR and GIT_INDEX_FILE, and with them the copy's
# git add would write to the caller's index.
ROG_LOCAL_ENV=(env -u GIT_DIR -u GIT_INDEX_FILE -u GIT_WORK_TREE -u GIT_COMMON_DIR)
ROG_COPY=
ROG_CHILD=
ROG_PARENT=

# rog_run_local CMD [ARG...]: runs CMD with ROG_LOCAL_ENV and waits for it. A
# TERM, INT, QUIT or HUP that reaches the script, even one sent to its PID
# alone, as `kill PID` does, stops CMD and every process below it, Nix
# included, before the EXIT trap removes the copy. Without this, `kill PID`
# left Nix running. CMD runs in the background so that bash runs the trap
# during `wait`; for a foreground command bash would hold the trap until Nix
# ended. CMD stays in the script's process group, so Ctrl-Z and a SIGKILL to
# the group reach it as they would in the foreground. As a background command
# CMD ignores INT and QUIT, so Ctrl-C and Ctrl-\ stop it through the trap.
rog_run_local() {
  local rc=0
  trap 'rog_stop_local 143' TERM
  trap 'rog_stop_local 130' INT
  trap 'rog_stop_local 131' QUIT
  trap 'rog_stop_local 129' HUP
  # Bash gives a background command /dev/null as stdin unless it names one.
  "${ROG_LOCAL_ENV[@]}" "$@" <&0 &
  ROG_CHILD=$! ROG_PARENT=$BASHPID
  wait "$ROG_CHILD" || rc=$?
  trap - TERM INT QUIT HUP
  ROG_CHILD=
  return "$rc"
}

# rog_stat PID: sets ROG_STAT to the fields of /proc/PID/stat after the
# command name, state first and parent PID second. The name sits in
# parentheses and may hold spaces and parentheses itself.
rog_stat() {
  local stat
  read -r stat 2>/dev/null <"/proc/$1/stat" || return 1
  ROG_STAT=${stat##*) }
}

# rog_alive PID: says whether PID runs. A zombie does not; it waits only for
# its parent to read its exit code.
rog_alive() {
  rog_stat "$1" && [[ ${ROG_STAT%% *} != Z ]]
}

# rog_tree PID: prints PID and the PID of every live process below it.
rog_tree() {
  local child
  rog_alive "$1" || return 0
  echo "$1"
  for child in $(ps -o pid= --ppid "$1"); do
    rog_tree "$child"
  done
}

# rog_cgroup: prints the local command's cgroup when it differs from the
# script's own, as under heavy's scope, and nothing otherwise. Bash may have
# reaped the command already, and then its PID can belong to another process,
# so the PID counts only while its parent is the shell that started it.
rog_cgroup() {
  local own child ppid
  rog_stat "$ROG_CHILD" || return 0
  read -r _ ppid _ <<<"$ROG_STAT"
  [[ $ppid == "$ROG_PARENT" ]] || return 0
  own=$(</proc/self/cgroup)
  child=$(cat "/proc/$ROG_CHILD/cgroup" 2>/dev/null) || return 0
  [[ $child == "$own" ]] || echo "${child#0::}"
}

# rog_procs CGROUP [PID...]: prints the PIDs of the local command's live
# processes. With CGROUP, every process in it counts, also one forked after the
# last look or re-parented after its parent ended. Without it, the walk from
# the command counts, plus each PID given that still runs, so a process seen
# once still counts after its parent ends.
rog_procs() {
  local cgroup=$1 pid
  shift
  if [[ -n $cgroup ]]; then
    cat "/sys/fs/cgroup$cgroup/cgroup.procs" 2>/dev/null || true
    return 0
  fi
  {
    rog_tree "$ROG_CHILD"
    for pid in "$@"; do
      if rog_alive "$pid"; then echo "$pid"; fi
    done
  } | sort -u
}

# rog_stop_local CODE: sends TERM to every process of the command
# rog_run_local started, again each ROG_STOP_STEP until none is left, then
# KILL to what remains after ROG_STOP_STEPS steps. It waits for the command
# and exits CODE, which runs the EXIT trap. It sends TERM whatever the signal
# was, because a background command of a script ignores INT and QUIT. It
# ignores a second signal, so the KILL step still runs; the stop takes
# ROG_STOP_STEPS steps at most.
ROG_STOP_STEP=0.1
# A guess: Nix printed "interrupted by the user" and ended within 44 ms of TERM
# on 2026-10-24, so 50 steps, about 5 s, leave it a wide margin.
ROG_STOP_STEPS=50
rog_stop_local() {
  local cgroup='' pids=() step
  trap '' TERM INT QUIT HUP
  if [[ -n $ROG_CHILD ]]; then
    for ((step = 0; step < ROG_STOP_STEPS; step++)); do
      # A signal can come before heavy's systemd-run has moved the command
      # into its scope, so look again each step. Once found, the cgroup
      # stays, also after the command itself has ended.
      [[ -n $cgroup ]] || cgroup=$(rog_cgroup)
      mapfile -t pids < <(rog_procs "$cgroup" "${pids[@]}")
      ((${#pids[@]})) || break
      kill -s TERM "${pids[@]}" 2>/dev/null || true
      read -rt "$ROG_STOP_STEP" <> <(:) || true
    done
    # cgroup.kill sends KILL to the whole cgroup at once, so a process that a
    # TERM handler started after the last look goes too.
    if ((${#pids[@]})) && ! { [[ -n $cgroup ]] && echo 1 >"/sys/fs/cgroup$cgroup/cgroup.kill"; } 2>/dev/null; then
      kill -s KILL "${pids[@]}" 2>/dev/null || true
    fi
    wait "$ROG_CHILD" 2>/dev/null || true
    ROG_CHILD=
  fi
  trap - TERM INT QUIT HUP
  exit "$1"
}

# rog_remote [ARG...] < SCRIPT: runs SCRIPT on the host in bash, with the
# copy's path as $1 and each ARG after it. The host's login shell is zsh, so
# the arguments go through printf %q. Data goes to the host in its own call,
# never beside a script, because the script already uses the call's stdin: bash
# drops a piped input and zsh merges it into the script.
#
# rog_remote runs under heavy when the host has it (home-manager/modules/heavy.nix),
# so each Nix call gets its own memory cap. rog_remote_light runs without it,
# for a call that runs no Nix.
rog_remote() {
  local args
  if ((ROG_LOCAL)); then
    if command -v heavy >/dev/null; then
      rog_run_local heavy bash -s -- "$ROG_COPY" "$@"
    else
      rog_run_local bash -s -- "$ROG_COPY" "$@"
    fi
    return
  fi
  args=$(printf '%q ' "$ROG_COPY" "$@")
  "${ROG_SSH[@]}" "$ROG_HOST" \
    "if command -v heavy >/dev/null; then exec heavy bash -s -- $args; else exec bash -s -- $args; fi"
}

rog_remote_light() {
  if ((ROG_LOCAL)); then
    rog_run_local bash -s -- "$ROG_COPY" "$@"
    return
  fi
  "${ROG_SSH[@]}" "$ROG_HOST" "bash -s -- $(printf '%q ' "$ROG_COPY" "$@")"
}

# rog_path: prints the copy as an rsync location, with the host in front when
# the copy is on nixos-rog.
rog_path() {
  if ((ROG_LOCAL)); then
    printf '%s/' "$ROG_COPY"
  else
    printf '%s:%s/' "$ROG_HOST" "$ROG_COPY"
  fi
}

# rog_copy_open [--no-local]: picks the host (rog_pick_host, which gets
# --no-local), makes the copy and sets the EXIT trap that removes it, so a
# caller sets no EXIT trap of its own.
rog_copy_open() {
  rog_pick_host "$@"
  # Each run gets its own copy, so two runs cannot remove each other's.
  if ((ROG_LOCAL)); then
    ROG_COPY=$(mktemp -d /tmp/check-nixos-config.XXXXXXXX)
  else
    ROG_COPY=$("${ROG_SSH[@]}" "$ROG_HOST" mktemp -d /tmp/check-nixos-config.XXXXXXXX)
  fi
  # The trap below removes the copy, so it must be exactly the new directory.
  if [[ ! $ROG_COPY =~ ^/tmp/check-nixos-config\.[A-Za-z0-9]{8}$ ]]; then
    echo "mktemp printed an unexpected path: $ROG_COPY" >&2
    exit 1
  fi
  # shellcheck disable=SC2016 # the remote bash expands $1
  trap 'rog_remote_light <<<"rm -rf -- \"\$1\"" || true' EXIT

  # A tracked file deleted in the working tree is listed but missing; the copy
  # leaves it out, as the working tree does.
  git ls-files -co --exclude-standard -z |
    rsync -a --from0 --ignore-missing-args --files-from=- ./ "$(rog_path)"
  # A git flake, like a checkout. Without git add, Nix would leave the new
  # files out of it.
  rog_remote_light <<'REMOTE'
set -e
cd "$1"
git init -q
git add -A
REMOTE
}
