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

# rog_run_local CMD [ARG...]: runs CMD with ROG_LOCAL_ENV in a process group of
# its own and waits for it. A TERM, INT or HUP to the script stops that whole
# group, Nix included, before the EXIT trap removes the copy; without it a
# script stopped by PID, as by timeout, left its Nix process running. Ctrl-C
# reaches the script only, because CMD's group is not the terminal's, so the
# trap passes it on.
rog_run_local() {
  local rc=0
  set -m
  "${ROG_LOCAL_ENV[@]}" "$@" &
  ROG_CHILD=$!
  set +m
  trap 'rog_stop_local TERM 143' TERM
  trap 'rog_stop_local INT 130' INT
  trap 'rog_stop_local HUP 129' HUP
  wait "$ROG_CHILD" || rc=$?
  trap - TERM INT HUP
  ROG_CHILD=
  return "$rc"
}

# rog_stop_local SIGNAL CODE: sends SIGNAL to the group rog_run_local started,
# waits for it and exits CODE, which runs the EXIT trap.
rog_stop_local() {
  trap - TERM INT HUP
  if [[ -n $ROG_CHILD ]]; then
    kill -s "$1" -- "-$ROG_CHILD" 2>/dev/null || true
    wait "$ROG_CHILD" 2>/dev/null || true
    ROG_CHILD=
  fi
  exit "$2"
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
