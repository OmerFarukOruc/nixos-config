#!/usr/bin/env bash
# Deploy from fedora-desktop. The target builds because fedora-desktop has no Nix.
# A host deploys itself when HOST is its own host name; the steps then run
# locally instead of over SSH.
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: ./deploy.sh [--allow-dirty] [--replace] HOST [switch|test|boot|prune]

switch is the default action. Use --allow-dirty only for an intentional deploy
of tracked modifications and non-ignored untracked files. Use --replace only
after the owner of a running release agrees that this deploy may drop its files.
EOF
}

allow_dirty=false
replace=false
while [[ ${1:-} == --* ]]; do
  case $1 in
    --allow-dirty) allow_dirty=true ;;
    --replace) replace=true ;;
    *)
      usage
      exit 64
      ;;
  esac
  shift
done

if (($# < 1 || $# > 2)); then
  usage
  exit 64
fi

host=$1
action=${2:-switch}
repo_dir=$(cd "$(dirname "$0")" && pwd)
# A dead connection ends after 30 s here and after 45 s in the target's sshd
# (nixosModules/connectivity.nix). The target's end frees the deploy lock that
# the connection holds.
ssh_opts=(-o ConnectTimeout=15 -o ServerAliveInterval=10 -o ServerAliveCountMax=3)
deployer=$(</proc/sys/kernel/hostname)
local_target=false
[[ $host == "$deployer" ]] && local_target=true

# Runs the script on stdin with bash on the target, with the arguments given.
# The arguments travel as a quoted "set --" line ahead of the script, because
# ssh joins its own arguments into one string for the remote login shell.
on_target() {
  if (($#)); then
    {
      printf 'set -- %s\n' "$(printf '%q ' "$@")"
      cat
    } | on_target
  elif $local_target; then
    (cd && bash -s)
  else
    ssh "${ssh_opts[@]}" "$host" bash -s
  fi
}

if [[ ! $host =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]]; then
  printf 'Invalid host name: %s\n' "$host" >&2
  exit 64
fi

case "$action" in
  switch | test | boot | prune) ;;
  *)
    printf 'Invalid action: %s (expected switch, test, boot, or prune)\n' "$action" >&2
    exit 64
    ;;
esac

if [[ $action == prune ]]; then
  on_target <<'REMOTE'
set -euo pipefail

state_dir=$HOME/.local/state/nixos-config-deploy
releases_dir=$state_dir/releases
current=
if [[ -L $state_dir/current ]]; then
  current=$(readlink -f -- "$state_dir/current")
fi
# The records of the releases that run or boot let the next deploy check them.
live=()
for link in /run/current-system /nix/var/nix/profiles/system; do
  system=$(readlink -f -- "$link" || true)
  [[ -n $system ]] && live+=(-e "system=$system")
done

mapfile -t releases < <(
  find "$releases_dir" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %p\n' 2>/dev/null |
    LC_ALL=C sort -rn |
    cut -d' ' -f2-
)

delete=()
for ((index = 5; index < ${#releases[@]}; index++)); do
  release=${releases[index]}
  if (( ${#live[@]} )) && grep -qxF "${live[@]}" -- "$release.source" 2>/dev/null; then
    continue
  fi
  if [[ $release != "$current" && $release == "$releases_dir/"* && ! -L $release ]]; then
    delete+=("$release")
    for record in "$release.source" "$release.blobs"; do
      [[ -e $record ]] && delete+=("$record")
    done
  fi
done

if (( ${#delete[@]} == 0 )); then
  printf '%s\n' 'No deploy releases are eligible for pruning.'
  exit 0
fi

printf '%s\n' 'Deploy releases scheduled for deletion:'
printf '  %s\n' "${delete[@]}"
printf '%s\n' \
  'The current release and the releases that run or boot are protected. Deleted candidates can be recreated by redeploying their Git revisions.'
rm -r -- "${delete[@]}"
REMOTE
  exit
fi

dirty=false
[[ -n $(git -C "$repo_dir" status --porcelain=v1 --untracked-files=normal) ]] && dirty=true
if [[ $dirty == true && $allow_dirty == false ]]; then
  printf '%s\n' \
    'Refusing to deploy a dirty source tree.' \
    'Commit or stash the changes, or rerun with --allow-dirty after reviewing them.' >&2
  exit 65
fi

deploy_state_dir=$(mktemp -d)
trap 'rm -rf -- "$deploy_state_dir"' EXIT
manifest="$deploy_state_dir/manifest"

# Include intentional dirty files but never ignored files.
while IFS= read -r -d '' path; do
  if [[ -f "$repo_dir/$path" || -L "$repo_dir/$path" ]]; then
    printf '%s\0' "$path"
  fi
done < <(git -C "$repo_dir" ls-files -co --exclude-standard -z) |
  LC_ALL=C sort -zu >"$manifest"

# The Git blob of every uploaded file, one "<blob><TAB><path>" line each.
blobs="$deploy_state_dir/blobs"
tr '\0' '\n' <"$manifest" >"$deploy_state_dir/paths"
paste <(cd "$repo_dir" && git hash-object --stdin-paths <"$deploy_state_dir/paths") \
  "$deploy_state_dir/paths" >"$blobs"

revision=$(git -C "$repo_dir" rev-parse HEAD)
release_id="$(date -u +%Y%m%dT%H%M%SZ)-${revision:0:12}-$$"
release_relative=".local/state/nixos-config-deploy/releases/$release_id"
# rsync ignores -e for a local path.
release_target=$host:$release_relative
$local_target && release_target=$HOME/$release_relative
rsync_cmd=(rsync -az -e "ssh ${ssh_opts[*]}")

# Where the release came from, next to the release as <id>.source. The promotion
# adds the system it built, which is how a later deploy finds the release that
# runs on the target.
branch=$(git -C "$repo_dir" branch --show-current)
record="deployer=$deployer
source=$repo_dir
branch=${branch:-detached}
revision=$revision
dirty=$dirty
action=$action
claude_config_dir=${CLAUDE_CONFIG_DIR:-}
started=$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# One deploy at a time per target. A shell on the target holds the lock while it
# reads this script's open pipe, so the lock goes when this script exits or its
# connection drops.
acquire_lock() {
  local state='' holder
  # No arguments, so the target shell reads this pipe directly and ends with it.
  coproc DEPLOY_LOCK { on_target; }
  trap '' PIPE
  {
    printf 'owner=%q\n' "$deployer:$repo_dir (${branch:-detached}, pid $$)"
    cat <<'REMOTE'
set -euo pipefail
state_dir=$HOME/.local/state/nixos-config-deploy
mkdir -p -- "$state_dir"
command -v flock >/dev/null || { echo no-flock; exit 0; }
exec 9>>"$state_dir/deploy.lock"
if ! flock -n 9; then
  echo busy
  cat -- "$state_dir/deploy.owner" 2>/dev/null || true
  exit 0
fi
printf '%s since %s\n' "$owner" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$state_dir/deploy.owner"
echo locked
exec cat >/dev/null
REMOTE
  } >&"${DEPLOY_LOCK[1]}" || true
  trap - PIPE
  if [[ -n ${DEPLOY_LOCK[0]:-} ]]; then
    IFS= read -r -t 60 -u "${DEPLOY_LOCK[0]}" state || state=
  fi
  case $state in
    locked) ;;
    busy)
      IFS= read -r -t 5 -u "${DEPLOY_LOCK[0]:-}" holder || holder=unknown
      printf 'Another deploy to %s is running: %s\n' "$host" "$holder" >&2
      exit 77
      ;;
    no-flock)
      printf 'flock is missing on %s, so the deploy cannot take its lock.\n' "$host" >&2
      exit 1
      ;;
    *)
      printf 'Could not take the deploy lock on %s.\n' "$host" >&2
      exit 1
      ;;
  esac
}

# Prints the system the target runs, which a rollback restores. A rollback
# timer from an earlier deploy means the target is not settled, so it exits 70.
target_system() {
  on_target <<'REMOTE'
set -euo pipefail
if systemctl is-active --quiet deploy-rollback.timer; then
  printf '%s\n' 'A rollback timer from an earlier deploy is still pending.' \
    'Wait for it to fire, or stop deploy-rollback.timer after checking the target.' >&2
  exit 70
fi
readlink -f /run/current-system
REMOTE
}

# A dropped connection frees the lock, and another deploy may have run since.
# Take the lock again and repeat the checks before the target changes. The
# running system is read again, because the rollback must restore that one.
ensure_lock() {
  [[ -n ${DEPLOY_LOCK_PID:-} ]] && kill -0 "$DEPLOY_LOCK_PID" 2>/dev/null && return 0
  printf 'The deploy lock on %s dropped with its connection. Taking it again.\n' "$host" >&2
  acquire_lock
  if [[ $replace == false ]]; then
    check_live_releases || return $?
  fi
  previous_system=$(target_system) || return $?
}

# Prints each path whose version in the live release ($1, a blobs file) is
# neither the candidate's nor anywhere in this checkout's history. A squash
# merge keeps the final version of each file, so work whose deployed files match
# what merged passes.
dropped_paths() {
  local history="$deploy_state_dir/history" mismatches="$deploy_state_dir/mismatches"
  awk -F '\t' '
    FILENAME == ARGV[1] { candidate[$2] = $1; next }
    candidate[$2] != $1 { print }
  ' "$blobs" "$1" >"$mismatches" || return $?
  [[ -s $mismatches ]] || return 0
  if [[ ! -f $history ]]; then
    git -C "$repo_dir" rev-list --objects HEAD | awk '{ print $1 }' >"$history.next" || return $?
    mv -- "$history.next" "$history" || return $?
  fi
  awk -F '\t' '
    FILENAME == ARGV[1] { known[$1] = 1; next }
    !($1 in known) { print $2 }
  ' "$history" "$mismatches"
}

# Prints the number of a merged PR that holds the release whose record is $1,
# when the merge is in this checkout's history. A squash merge keeps only the
# final version of each file, so a test deploy of an earlier commit of that PR
# holds versions that are in no commit here, though the work merged. A dirty
# release holds edits no commit has, so it never matches. Without GitHub, the
# release does not match and the check refuses as before.
merged_pr_of_release() {
  local revision pr merge
  grep -qx 'dirty=false' -- "$1" || return 1
  revision=$(sed -n 's/^revision=//p' -- "$1")
  [[ $revision =~ ^[0-9a-f]{40}$ ]] || return 1
  while read -r pr merge; do
    if [[ -n $merge ]] && git -C "$repo_dir" merge-base --is-ancestor "$merge" HEAD 2>/dev/null; then
      printf '%s\n' "$pr"
      return 0
    fi
    # The commit's own PR list; a search would also match a PR that only cites
    # the SHA in its text.
  done < <(cd "$repo_dir" && timeout 30 gh api "repos/{owner}/{repo}/commits/$revision/pulls" \
    --jq '.[] | select(.merged_at) | "\(.number) \(.merge_commit_sha // "")"' 2>/dev/null)
  return 1
}

# Prints how to continue after the release check refused. It reads only local
# refs, so a fetch that has not run yet can leave a stale clone unnamed.
checkout_hint() {
  local behind
  if ! git -C "$repo_dir" rev-parse -q --verify refs/remotes/origin/main >/dev/null; then
    :
  elif ! git -C "$repo_dir" merge-base HEAD origin/main >/dev/null; then
    printf '%s\n' 'This checkout shares no history with origin/main, likely because the' \
      "repository's history was rewritten. If it holds no work of its own, run" \
      'git fetch origin && git reset --hard origin/main, then deploy again.' >&2
    return 0
  elif git -C "$repo_dir" merge-base --is-ancestor HEAD origin/main; then
    behind=$(git -C "$repo_dir" rev-list --count HEAD..origin/main)
    if ((behind > 0)); then
      printf 'This checkout is behind origin/main by %d commit(s). Run git pull, then deploy again.\n' "$behind" >&2
      return 0
    fi
  fi
  printf '%s\n' 'Merge that work into this checkout, or rerun with --replace after its owner agrees.' >&2
}

# A deploy replaces what runs on the target and its boot default. Refuse when
# either came from another checkout and holds files this deploy would drop.
# The current link names only the last promoted release, which a reboot or a
# later test deploy can leave behind, so the records are matched by system.
check_live_releases() {
  local live role id from_host from_dir record_file dropped pr
  local -A seen=()
  live=$(
    on_target <<'REMOTE'
set -euo pipefail
shopt -s nullglob
records=("$HOME"/.local/state/nixos-config-deploy/releases/*.source)
for pair in running:/run/current-system boot:/nix/var/nix/profiles/system; do
  role=${pair%%:*}
  system=$(readlink -f "${pair#*:}" || true)
  [[ -n $system ]] || continue
  match=
  if (( ${#records[@]} )); then
    match=$(grep -lxF "system=$system" -- "${records[@]}" | LC_ALL=C sort | tail -n 1 || true)
  fi
  if [[ -z $match ]]; then
    printf '%s\n' "$role"
    continue
  fi
  id=${match##*/}
  printf '%s %s %s %s\n' "$role" "${id%.source}" \
    "$(sed -n 's/^deployer=//p' "$match")" "$(sed -n 's/^source=//p' "$match")"
done
REMOTE
  ) || return $?
  while read -r role id from_host from_dir; do
    if [[ -z $id ]]; then
      printf 'The %s system on %s has no release record, so this deploy cannot check it.\n' "$role" "$host" >&2
      continue
    fi
    [[ -n ${seen[$id]:-} || ($from_host == "$deployer" && $from_dir == "$repo_dir") ]] && continue
    seen[$id]=1
    record_file="$deploy_state_dir/$id.source"
    "${rsync_cmd[@]}" "${release_target%/*}/$id.source" "${release_target%/*}/$id.blobs" "$deploy_state_dir/" ||
      return $?
    dropped=$(dropped_paths "$deploy_state_dir/$id.blobs") || return $?
    [[ -z $dropped ]] && continue
    if pr=$(merged_pr_of_release "$record_file"); then
      printf 'The %s system on %s comes from release %s, a commit of PR #%s, which merged into this checkout.\n' \
        "$role" "$host" "$id" "$pr" >&2
      continue
    fi
    printf 'The %s system on %s comes from release %s:\n' "$role" "$host" "$id" >&2
    sed 's/^/  /' "$record_file" >&2
    printf '%s\n' 'This checkout lacks its version of these files, so this deploy would drop them:' >&2
    # Indents every line, which a parameter expansion would not do for the first.
    # shellcheck disable=SC2001
    sed 's/^/  /' <<<"$dropped" >&2
    checkout_hint
    return 78
  done <<<"$live"
}

acquire_lock
if [[ $replace == false ]]; then
  check_live_releases || exit $?
fi

printf 'Uploading %s to release %s on %s.\n' "$repo_dir" "$release_id" "$host"
on_target "$release_relative" "$record" <<'REMOTE'
set -euo pipefail
release_dir=$HOME/$1
mkdir -p -- "$(dirname "$release_dir")"
mkdir -- "$release_dir"
printf '%s\n' "$2" >"$release_dir.source"
REMOTE

"${rsync_cmd[@]}" --from0 --files-from="$manifest" "$repo_dir/" "$release_target/"

# switch and test activate a system the deployer cannot check beforehand. A
# rollback timer on the target restores the previous system unless a fresh SSH
# login confirms the new one, so a bad activation cannot strand the box. The
# timer starts before activation and must outlast the activation with its wait
# after a dropped connection (180 s, plus 20 s for the last poll), the confirm
# loop (up to 6 x 20 s when SSH lags) and the session check (15 s to connect,
# 20 s sleep): 355 s at worst.
rollback_seconds=420
activation_seconds=180

# A new SSH connection proves the target is still reachable; a host that
# deploys itself checks the same units locally.
fresh_login() {
  if $local_target; then
    on_target
  else
    ssh "${ssh_opts[@]}" -o BatchMode=yes -o ControlPath=none "$host" bash -s
  fi
}

confirm_target() {
  local _
  for _ in 1 2 3 4 5 6; do
    if fresh_login <<'REMOTE'
set -e
for unit in sshd tailscaled; do
  systemctl is-active --quiet "$unit"
done
REMOTE
    then
      return 0
    fi
    sleep 5
  done
  return 1
}

# SSH can still answer while the switch broke the desktop. The deploy user's
# running services form the session: the compositor, the shell, the keyring.
# Services a timer, socket or path started, apps a launcher or autostart
# started (app-*), systemd-run jobs (run-*) and transient D-Bus services
# (dbus-*) come and go on their own and are left out.
session_services() {
  on_target <<'REMOTE'
set -euo pipefail
export XDG_RUNTIME_DIR=/run/user/$(id -u)
[[ -S $XDG_RUNTIME_DIR/bus ]] || exit 0
listing=$(systemctl --user list-units --type=service --state=running --plain --no-legend |
  awk '$1 !~ /^(app|run|dbus)-/ { print $1 }')
[[ -n $listing ]] || exit 0
mapfile -t units <<<"$listing"
systemctl --user show -p Id -p TriggeredBy -- "${units[@]}" |
  awk -F= '$1 == "Id" { id = $2 } $1 == "TriggeredBy" && $2 == "" { print id }'
REMOTE
}

# A session service that the switch broke has failed or waits to restart. One
# that exited cleanly, or that the new system dropped, is fine.
check_session() {
  (($#)) || return 0
  on_target "$@" <<'REMOTE'
set -uo pipefail
export XDG_RUNTIME_DIR=/run/user/$(id -u)
# With systemd's default limit of 5 starts in 10 s, a service that crashes on
# start has failed for good by then.
sleep 20
# A failed query, such as a user bus lost in the switch, fails the check.
broken=$(systemctl --user show -p Id -p ActiveState -p SubState -- "$@" | awk -F= '
  $1 == "Id" { id = $2 } $1 == "ActiveState" { state = $2 }
  $1 == "SubState" && (state == "failed" || $2 == "auto-restart") { print id }') || {
  printf '%s\n' 'Could not query the session services after the switch.' >&2
  exit 1
}
[[ -z $broken ]] && exit 0
printf 'These session services broke after the switch: %s\n' "${broken//$'\n'/ }" >&2
exit 1
REMOTE
}

new_system=
previous_system=
# The packages the new system no longer holds, as dix lists them.
removed_packages=

# Build first. Nothing changes on the target until this succeeds.
build_candidate() {
  previous_system=$(target_system) || return $?
  local output
  output=$(
    on_target "$host" "$release_relative" "$action" <<'REMOTE'
set -euo pipefail

host=$1
release_dir=$HOME/$2
action=$3

# heavy (machines/nixos-rog/heavy.nix) caps the evaluation's memory on a host
# that has it. The hourly updater's PATH lacks it, so its deploy runs plain nix
# under the unit's own MemoryHigh.
nix=(nix)
if command -v heavy >/dev/null; then nix=(heavy nix); fi
new=$("${nix[@]}" build --no-link --print-out-paths \
  "$release_dir#nixosConfigurations.$host.config.system.build.toplevel")

# What the new system changes, for the deployer to read before it activates.
# The first deploy that adds dix runs on a system without it.
if command -v dix >/dev/null; then
  if diff=$(dix --color never "$(readlink -f /run/current-system)" "$new" 2>&1); then
    printf '%s\n' "$diff" >&2
    # The deploy names these again when it ends, where the deployer reads them.
    removed=$(awk '/^REMOVED$/ { r = 1; next } r && /^\[R/ { print $2; next } { r = 0 }' <<<"$diff" |
      paste -sd ' ') || removed=
    [[ -z $removed ]] || printf 'removed=%s\n' "$removed"
  else
    printf '%s\n' "$diff" 'dix could not compare the running and the new system.' >&2
  fi
fi

# A unit ordered after a service that itself starts after the target that
# wants the unit forms an ordering cycle; the next boot then waits on it and
# never reaches that target. The candidate's systemd-analyze reads only the
# candidate's units; it exits 0 also when it finds a cycle. Without --man=no it
# looks up each unit's man pages and fails where man is not on PATH, as in the
# updater's service.
analysis=$(SYSTEMD_UNIT_PATH="$new/etc/systemd/system" "$new/sw/bin/systemd-analyze" verify --man=no default.target 2>&1) ||
  printf '%s\n' "$analysis" 'systemd-analyze could not check the new units for an ordering cycle.' >&2
if grep -q 'Found ordering cycle' <<<"$analysis"; then
  printf '%s\n' "$analysis" 'The new system would not finish booting. Nothing on the target changed.' >&2
  exit 80
fi

# When the ESP did not mount, the boot entries would land in the root
# filesystem's /boot, where the firmware never looks.
if [[ $action != test ]] && ! mountpoint -q /boot; then
  printf '%s\n' '/boot is not mounted, so the boot entries would miss the ESP.' \
    'Nothing on the target changed. Mount the ESP and deploy again.' >&2
  exit 79
fi

# Each boot entry copies its kernel and initrd to the ESP before the installer
# removes old ones, so a nearly full ESP fails halfway through. Count every
# distinct kernel and initrd of the candidate and its specialisations, even
# those already on the ESP, and stop before anything on the target changes.
# Every host has a 4 GiB ESP; 1 GiB left free covers a few more generations.
esp_headroom=$((1024 * 1024 * 1024))
check_esp_space() {
  local esp=/boot needed=0 free path
  local -A seen=()
  for path in "$new"/kernel "$new"/initrd "$new"/specialisation/*/kernel "$new"/specialisation/*/initrd; do
    [[ -e $path ]] || continue
    path=$(readlink -f -- "$path")
    [[ -n ${seen[$path]:-} ]] && continue
    seen[$path]=1
    needed=$((needed + $(stat -c %s -- "$path")))
  done
  free=$(df -B1 --output=avail -- "$esp" | tail -n 1)
  if (( free < needed + esp_headroom )); then
    printf 'The ESP at %s has %d MiB free; the boot entries need up to %d MiB plus %d MiB headroom.\n' \
      "$esp" $((free / 1048576)) $((needed / 1048576)) $((esp_headroom / 1048576)) >&2
    printf '%s\n' 'Nothing on the target changed. Free space on the ESP or lower the generation limit.' >&2
    exit 74
  fi
}

if [[ $action != test ]]; then
  check_esp_space
fi

printf '%s\n' "$new"
REMOTE
  ) || return $?
  new_system=${output##*$'\n'}
  removed_packages=$(sed -n 's/^removed=//p' <<<"$output")
}

# The timer stops only after the rollback succeeded. When it failed, the timer
# stays armed and repeats the restore at its deadline.
roll_back_now() {
  local rollback_status=0
  on_target <<'REMOTE' || rollback_status=$?
sudo systemctl start --wait deploy-rollback.service || exit 1
sudo systemctl stop deploy-rollback.timer || exit 2
REMOTE
  case $rollback_status in
    0) ;;
    2) printf '%s\n' 'The previous system is back, but the rollback timer would not stop. Stop deploy-rollback.timer on the target.' >&2 ;;
    *)
      printf '%s\n' \
        'THE ROLLBACK FAILED. The target may still run the candidate system.' \
        'The boot default is unchanged, because the deploy never made the candidate the boot default.' \
        'A reboot restores the previous system. The rollback timer stays armed and repeats the restore at its deadline.' >&2
      ;;
  esac
}

# After a dropped connection the activation keeps running in its unit, which
# records "<release> <exit status>" when it ends. Prints that status, "lost" when
# the unit ended without one, or "running" when none came before the deadline.
wait_activation() {
  local deadline=$1 result
  while :; do
    result=$(
      {
        printf 'release=%q\n' "$release_id"
        cat <<'REMOTE'
status_file=/run/deploy-activate.status
status=$(sed -n "s/^$release //p" "$status_file" 2>/dev/null)
if [[ -z $status ]] && systemctl is-active --quiet deploy-activate.service; then
  echo running
  exit 0
fi
# The unit may have ended between the two reads.
[[ -n $status ]] || status=$(sed -n "s/^$release //p" "$status_file" 2>/dev/null)
echo "${status:-lost}"
REMOTE
      } | fresh_login
    ) || result=running
    [[ $result == running ]] || break
    ((SECONDS < deadline)) || break
    sleep 5
  done
  [[ $result =~ ^([0-9]+|running|lost)$ ]] || result=lost
  printf '%s\n' "$result"
}

# Arm the rollback, then activate in a system service so an SSH drop during
# the network restart cannot kill the activation.
activate_with_rollback() {
  local activate_status=0 session_list activation_deadline
  local -a session=()

  session_list=$(session_services) || {
    printf '%s\n' 'Could not list the session services before activation. Nothing on the target changed.' >&2
    return 1
  }
  [[ -z $session_list ]] || mapfile -t session <<<"$session_list"
  activation_deadline=$((SECONDS + activation_seconds))
  on_target "$new_system" "$previous_system" "$rollback_seconds" "$release_id" <<'REMOTE' || activate_status=$?
set -uo pipefail

new=$1
previous=$2
seconds=$3
release=$4

# AccuracySec defaults to one minute, which would delay the rollback.
sudo systemd-run --quiet --no-ask-password --collect --unit=deploy-rollback \
  --on-active="$seconds" --timer-property=AccuracySec=1s \
  "$previous/bin/switch-to-configuration" test || exit 71

# The unit records its own exit status, which --wait loses when SSH drops.
started=$(date +%s)
sudo systemd-run --quiet --no-ask-password --collect --unit=deploy-activate \
  --service-type=exec --wait "$BASH" -c '
"$1/bin/switch-to-configuration" test
status=$?
printf "%s %s\n" "$2" "$status" >/run/deploy-activate.status
exit "$status"' _ "$new" "$release"
status=$?
# Only this activation's output; systemd's lines for the unit repeat its whole
# command line.
sudo journalctl --no-pager -o cat _SYSTEMD_UNIT=deploy-activate.service --since "@$started" | tail -n 30

exit "$status"
REMOTE

  if ((activate_status == 71)); then
    printf '%s\n' 'The rollback timer could not be armed, so nothing was activated.' >&2
    return 71
  fi
  if ((activate_status == 255)); then
    printf '%s\n' 'The connection dropped during activation. Waiting for its result.' >&2
    activate_status=$(wait_activation "$activation_deadline")
    case $activate_status in
      running)
        printf 'The activation reported no result in time. The previous system returns within %d seconds.\n' \
          "$rollback_seconds" >&2
        return 1
        ;;
      lost)
        printf '%s\n' 'The activation ended without a result.' >&2
        activate_status=1
        ;;
    esac
  fi
  if ((activate_status != 0)); then
    printf 'Activation failed (exit %d). Restoring the previous system now.\n' "$activate_status" >&2
    roll_back_now
    return "$activate_status"
  fi

  if ! confirm_target; then
    printf 'The target did not answer a fresh login. The previous system returns within %d seconds.\n' \
      "$rollback_seconds" >&2
    return 1
  fi

  if ! check_session "${session[@]}"; then
    printf '%s\n' 'The desktop session broke. Restoring the previous system now.' >&2
    roll_back_now
    return 75
  fi
}

# Disarm the rollback only while the target still runs the candidate, make the
# confirmed build the boot default unless the action is test, and promote the
# release.
finish_release() {
  on_target "$action" "$release_relative" "$new_system" <<'REMOTE'
set -euo pipefail

action=$1
release_dir=$HOME/$2
new=$3
state_dir=$HOME/.local/state/nixos-config-deploy

running_candidate() {
  [[ $(readlink -f /run/current-system) == "$new" ]] && ! systemctl is-active --quiet deploy-rollback.service
}

if [[ $action != boot ]]; then
  running_candidate || { printf '%s\n' 'The rollback already ran. The target is not on the candidate.' >&2; exit 72; }
  sudo systemctl stop deploy-rollback.timer
  running_candidate || { printf '%s\n' 'The rollback ran during confirmation.' >&2; exit 72; }
fi


# The two steps nixos-rebuild runs for boot, applied to the build that was
# already made instead of a second evaluation. When the boot loader install
# fails, the system profile and the boot entries go back to the previous
# generation, so the next boot does not depend on a half-written ESP.
if [[ $action != test ]]; then
  profile=/nix/var/nix/profiles/system
  previous_link=$(readlink "$profile")
  previous_profile=$(readlink -f "$profile")
  sudo nix-env --profile "$profile" --set "$new"
  new_link=$(readlink "$profile")
  if ! sudo "$new/bin/switch-to-configuration" boot; then
    printf '%s\n' 'Installing the boot entries failed. Restoring the previous boot default.' >&2
    # Drop the new generation, so the boot menu written next does not list it.
    # Links are named system-<generation>-link.
    # Limine makes the newest generation the default, so the new one must go.
    # A failure here must not skip reinstalling the previous entries below.
    restored=true
    if [[ $new_link != "$previous_link" ]]; then
      sudo nix-env --profile "$profile" --switch-generation "${previous_link//[!0-9]/}" || restored=false
      sudo nix-env --profile "$profile" --delete-generations "${new_link//[!0-9]/}" || restored=false
    fi
    if ! sudo "$previous_profile/bin/switch-to-configuration" boot; then
      printf '%s\n' 'Reinstalling the previous boot entries failed too. Check the ESP before rebooting.' >&2
    elif ! $restored; then
      printf '%s\n' 'Removing the new generation from the system profile failed, so Limine may still default to it. Check before rebooting.' >&2
    else
      printf 'The boot default is %s again.\n' "$previous_profile" >&2
    fi
    exit 73
  fi
fi

printf 'system=%s\n' "$new" >>"$release_dir.source"
next_link=$state_dir/current.next.$$
trap 'rm -f -- "$next_link"' EXIT
ln -s -- "$release_dir" "$next_link"
mv -Tf -- "$next_link" "$state_dir/current"
trap - EXIT
printf 'Promoted release %s.\n' "$release_dir"
REMOTE
}

# The build locks inputs that the uploaded flake.lock lacks. Fetch that lock
# before the target changes, so a copy failure cannot follow a promotion.
deploy() {
  build_candidate || return $?
  "${rsync_cmd[@]}" "$release_target/flake.lock" "$deploy_state_dir/flake.lock" || return $?
  # Record the lock the build completed, the version a later commit keeps.
  local lock_blob
  lock_blob=$(git -C "$repo_dir" hash-object -- "$deploy_state_dir/flake.lock") || return $?
  awk -F '\t' -v lock="$lock_blob" \
    'BEGIN { OFS = FS } $2 == "flake.lock" { $1 = lock } { print }' "$blobs" >"$blobs.final" || return $?
  "${rsync_cmd[@]}" "$blobs.final" "$release_target.blobs" || return $?
  ensure_lock || return $?
  # From here the pending rollback timer stops any other deploy at its build
  # step, so a lock that drops during activation needs no retake.
  if [[ $action != boot ]]; then
    activate_with_rollback || return $?
  fi
  finish_release
}

if deploy; then
  cp -- "$deploy_state_dir/flake.lock" "$repo_dir/flake.lock"
  if [[ -n $removed_packages ]]; then
    printf 'This deploy removed: %s.\n' "${removed_packages// /, }"
  fi
  printf 'Deployment completed from release %s.\n' "$release_id"
else
  status=$?
  printf 'Deployment failed on %s (exit %d).\n' "$host" "$status" >&2
  printf 'The failed candidate remains at ~/%s for inspection.\n' "$release_relative" >&2
  printf '%s\n' 'The previous current release and local flake.lock were not changed.' >&2
  exit "$status"
fi
