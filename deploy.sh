#!/usr/bin/env bash
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
    ssh "${ssh_opts[@]}" "$target" bash -s
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

target=$host
if ! $local_target; then
  eval_nix=(nix)
  if command -v heavy >/dev/null; then eval_nix=(heavy nix); fi
  if ! login=$("${eval_nix[@]}" eval --raw --no-write-lock-file \
    "$repo_dir#nixosConfigurations.$host.config.oruc.machine.deployLogin" \
    --apply 'login: if login == null then "" else login'); then
    printf 'Could not read deployLogin of %s from the machine records.\n' "$host" >&2
    exit 1
  fi
  target=${login:+$login@}$host
fi

if [[ $action == prune ]]; then
  on_target <<'REMOTE'
set -euo pipefail

state_dir=$HOME/.local/state/nixos-config-deploy
releases_dir=$state_dir/releases
current=
if [[ -L $state_dir/current ]]; then
  current=$(readlink -f -- "$state_dir/current")
fi
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
tree_status=$(git -C "$repo_dir" status --porcelain=v1 --untracked-files=normal)
[[ -n $tree_status ]] && dirty=true
if [[ $dirty == true && $allow_dirty == false ]]; then
  printf '%s\n' \
    'Refusing to deploy a dirty source tree.' \
    'Commit or stash the changes, or rerun with --allow-dirty after reviewing them.' >&2
  exit 65
fi

deploy_state_dir=$(mktemp -d)
trap 'rm -rf -- "$deploy_state_dir"' EXIT
manifest="$deploy_state_dir/manifest"

git -C "$repo_dir" ls-files -co --exclude-standard -z |
  while IFS= read -r -d '' path; do
    if [[ -f "$repo_dir/$path" || -L "$repo_dir/$path" ]]; then
      printf '%s\0' "$path"
    fi
  done |
  LC_ALL=C sort -zu >"$manifest"

blobs="$deploy_state_dir/blobs"
GIT_INDEX_FILE="$deploy_state_dir/index" git -C "$repo_dir" update-index --add --info-only -z --stdin <"$manifest"
GIT_INDEX_FILE="$deploy_state_dir/index" git -C "$repo_dir" -c core.quotepath=off \
  ls-files --format='%(objectname)%x09%(path)' >"$blobs"

revision=$(git -C "$repo_dir" rev-parse HEAD)
release_id="$(date -u +%Y%m%dT%H%M%SZ)-${revision:0:12}-$$"
release_relative=".local/state/nixos-config-deploy/releases/$release_id"
release_target=$target:$release_relative
$local_target && release_target=$HOME/$release_relative
rsync_cmd=(rsync -az -e "ssh ${ssh_opts[*]}")

branch=$(git -C "$repo_dir" branch --show-current)
record="deployer=$deployer
source=$repo_dir
branch=${branch:-detached}
revision=$revision
dirty=$dirty
action=$action
claude_config_dir=${CLAUDE_CONFIG_DIR:-}
started=$(date -u +%Y-%m-%dT%H:%M:%SZ)"

lock_owner="$deployer:$repo_dir (${branch:-detached}, pid $$)"
lock_free=252
own_lock_seconds=50
lock_end_seconds=40

acquire_lock() {
  local lock_in lock_out state holder deadline=$((SECONDS + own_lock_seconds))
  while true; do
    state='' holder=unknown
    coproc DEPLOY_LOCK { on_target; }
    if [[ -n ${DEPLOY_LOCK[0]:-} ]]; then
      exec {lock_in}>&"${DEPLOY_LOCK[1]}" {lock_out}<&"${DEPLOY_LOCK[0]}"
      trap '' PIPE
      {
        printf 'owner=%q\n' "$lock_owner"
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
case $(systemctl show -p ActiveState --value nixos-upgrade.service) in
  activating | active | deactivating | reloading)
    echo busy
    echo "nixos-upgrade.service, which installs main"
    exit 0
    ;;
esac
printf '%s since %s\n' "$owner" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$state_dir/deploy.owner"
echo locked
exec cat >/dev/null
REMOTE
      } >&"$lock_in" || true
      trap - PIPE
      exec {lock_in}>&-
      IFS= read -r -t 60 -u "$lock_out" state || state=
      if [[ $state == busy ]]; then
        IFS= read -r -t 5 -u "$lock_out" holder || holder=unknown
      fi
      exec {lock_out}<&-
    fi
    case $state in
      locked) return 0 ;;
      busy)
        if [[ $holder == "$lock_owner since "* ]] && ((SECONDS < deadline)); then
          sleep 5
          continue
        fi
        printf 'Another deploy to %s is running: %s\n' "$host" "$holder" >&2
        return 77
        ;;
      no-flock)
        printf 'flock is missing on %s, so the deploy cannot take its lock.\n' "$host" >&2
        return 1
        ;;
      *)
        printf 'Could not take the deploy lock on %s.\n' "$host" >&2
        return 1
        ;;
    esac
  done
}

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

lock_held() {
  local pid=${DEPLOY_LOCK_PID:-}
  [[ -n $pid ]] && kill -0 "$pid" 2>/dev/null
}

await_lock_end() {
  local deadline=$((SECONDS + lock_end_seconds))
  while lock_held && ((SECONDS < deadline)); do
    sleep 1
  done
  ! lock_held
}

retake_lock() {
  printf 'The deploy lock on %s dropped with its connection. Taking it again.\n' "$host" >&2
  acquire_lock
}

ensure_lock() {
  lock_held && return 0
  retake_lock || return $?
  if [[ $replace == false ]]; then
    check_live_releases || return $?
  fi
  previous_system=$(target_system) || return $?
}

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
  done < <(cd "$repo_dir" && timeout 30 gh api "repos/{owner}/{repo}/commits/$revision/pulls" \
    --jq '.[] | select(.merged_at) | "\(.number) \(.merge_commit_sha // "")"' 2>/dev/null)
  return 1
}

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
    if grep -q $'^\t' -- "$deploy_state_dir/$id.blobs"; then
      printf 'The %s system on %s comes from release %s, whose blob list lacks hashes, so this deploy cannot check it.\n' \
        "$role" "$host" "$id" >&2
      continue
    fi
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

acquire_lock || exit $?
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
install_seconds=300
unit_running=254
unit_lost=253

fresh_login() {
  if $local_target; then
    on_target
  else
    ssh "${ssh_opts[@]}" -o BatchMode=yes -o ControlPath=none "$target" bash -s
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

session_services() {
  on_target <<'REMOTE'
set -euo pipefail
export XDG_RUNTIME_DIR=/run/user/$(id -u)
[[ -S $XDG_RUNTIME_DIR/bus ]] || exit 0
ignore=()
[[ ! -r /etc/nixos-config-deploy/session-ignore ]] || mapfile -t ignore </etc/nixos-config-deploy/session-ignore
listing=$(systemctl --user list-units --type=service --state=running --plain --no-legend |
  awk '$1 !~ /^(app|run|dbus)-/ { print $1 }' |
  while read -r unit; do
    for glob in "${ignore[@]}"; do
      # shellcheck disable=SC2053
      [[ $unit == $glob ]] && continue 2
    done
    printf '%s\n' "$unit"
  done)
[[ -n $listing ]] || exit 0
mapfile -t units <<<"$listing"
systemctl --user show -p Id -p TriggeredBy -- "${units[@]}" |
  awk -F= '$1 == "Id" { id = $2 } $1 == "TriggeredBy" && $2 == "" { print id }'
REMOTE
}

check_session() {
  (($#)) || return 0
  on_target "$@" <<'REMOTE'
set -uo pipefail
export XDG_RUNTIME_DIR=/run/user/$(id -u)
sleep 20
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
removed_packages=

build_candidate() {
  previous_system=$(target_system) || return $?
  local output
  output=$(
    on_target "$host" "$release_relative" "$action" <<'REMOTE'
set -euo pipefail

host=$1
release_dir=$HOME/$2
action=$3

nix=(nix)
if command -v heavy >/dev/null; then nix=(heavy nix); fi
new=$("${nix[@]}" build --no-link --print-out-paths \
  "$release_dir#nixosConfigurations.$host.config.system.build.toplevel")

if command -v dix >/dev/null; then
  if diff=$(dix --color never diff "$(readlink -f /run/current-system)" "$new" 2>&1); then
    printf '%s\n' "$diff" >&2
    removed=$(awk '/^REMOVED( \(|$)/ { r = 1; next } r && /^\[R/ { print $2; next } { r = 0 }' <<<"$diff" |
      paste -sd ' ') || removed=
    [[ -z $removed ]] || printf 'removed=%s\n' "$removed"
  else
    printf '%s\n' "$diff" 'dix could not compare the running and the new system.' >&2
  fi
fi

signer=sw/bin/sign-installed-limine
secure_boot=/sys/firmware/efi/efivars/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c
if [[ $action != test && ! -e $new/$signer && -e /sys/firmware/efi ]] &&
  [[ -e /run/current-system/$signer || -e /nix/var/nix/profiles/system/$signer ]] &&
  { ! enforced=$(od -An -tx1 "$secure_boot" 2>/dev/null | tr -d ' \n') || [[ ${enforced:8} != 00 ]]; }; then
  printf '%s\n' "The firmware of $host enforces Secure Boot, and the new system does not sign Limine, so the firmware would refuse the boot loader it installs." \
    'Nothing on the target changed. Set Secure Boot to Disabled in the firmware setup first, then deploy again.' >&2
  exit 81
fi

# A unit ordered after a service that itself starts after the target that
# wants the unit forms an ordering cycle; the next boot then waits on it and
# never reaches that target. The candidate's systemd-analyze reads only the
# candidate's units; it exits 0 also when it finds a cycle. Without --man=no it
# looks up each unit's man pages and fails where man is not on PATH, as in the
# deploy unit's service.
analysis=$(SYSTEMD_UNIT_PATH="$new/etc/systemd/system" "$new/sw/bin/systemd-analyze" verify --man=no default.target 2>&1) ||
  printf '%s\n' "$analysis" 'systemd-analyze could not check the new units for an ordering cycle.' >&2
if grep -q 'Found ordering cycle' <<<"$analysis"; then
  printf '%s\n' "$analysis" 'The new system would not finish booting. Nothing on the target changed.' >&2
  exit 80
fi

if [[ $action != test ]] && ! mountpoint -q /boot; then
  printf '%s\n' '/boot is not mounted, so the boot entries would miss the ESP.' \
    'Nothing on the target changed. Mount the ESP and deploy again.' >&2
  exit 79
fi

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

poll_target() {
  local deadline=$1 script result
  script=$(cat)
  while :; do
    result=$(fresh_login <<<"$script") || result=running
    [[ $result == running ]] || break
    ((SECONDS < deadline)) || break
    sleep 5
  done
  printf '%s\n' "$result"
}

unit_ended() {
  case $(systemctl is-active "$1") in
    inactive | failed) return 0 ;;
  esac
  return 1
}

target_state() {
  {
    declare -f recorded_status unit_ended
    printf 'release=%q\n' "$release_id"
    cat <<'REMOTE'
timer=$(systemctl is-active deploy-rollback.timer)
if ! unit_ended deploy-rollback.service || [[ $timer != active && $timer != inactive ]]; then
  echo running
else
  ran=$(recorded_status "$release" deploy-rollback)
  printf '%s %s %s\n' "$(readlink -f /run/current-system)" "$timer" "${ran:-none}"
fi
REMOTE
  } | poll_target "$((SECONDS + activation_seconds))"
}

roll_back_now() {
  local result state
  on_target <<'REMOTE' || true
sudo systemctl start deploy-rollback.service
REMOTE
  result=$(wait_unit deploy-rollback "$((SECONDS + activation_seconds))")
  if [[ $result == 0 ]]; then
    on_target <<'REMOTE' || true
sudo systemctl stop deploy-rollback.timer
REMOTE
    state=$(target_state)
    case $state in
      "$previous_system inactive "*) ;;
      "$previous_system active "* | running)
        printf '%s\n' 'deploy-rollback.service recorded status 0, so the previous system is back, but the rollback timer still reads active, or its state could not be read. Stop deploy-rollback.timer on the target.' >&2
        ;;
      *)
        printf 'deploy-rollback.service recorded status 0, but the target runs %s. A reboot restores the previous system, because the deploy never made the candidate the boot default.\n' "${state%% *}" >&2
        ;;
    esac
    return 0
  fi
  printf '%s\n' \
    "THE ROLLBACK FAILED (deploy-rollback.service result: $result). The target may still run the candidate system." \
    'The boot default is unchanged, because the deploy never made the candidate the boot default.' \
    'A reboot restores the previous system. The rollback timer stays armed and repeats the restore at its deadline.' >&2
}

recorded_status() {
  sed -n "s/^$1 \([0-9]\{1,3\}\)$/\1/p" "/run/$2.status" 2>/dev/null
}

wait_unit() {
  local unit=$1 deadline=$2 result
  result=$({
    declare -f recorded_status unit_ended
    printf 'release=%q unit=%q\n' "$release_id" "$unit"
    cat <<'REMOTE'
status=$(recorded_status "$release" "$unit")
if [[ -z $status ]] && ! unit_ended "$unit.service"; then
  echo running
  exit 0
fi
[[ -n $status ]] || status=$(recorded_status "$release" "$unit")
echo "${status:-lost}"
REMOTE
  } | poll_target "$deadline")
  [[ $result =~ ^([0-9]+|running|lost)$ ]] || result=lost
  printf '%s\n' "$result"
}

recorded_unit() {
  local unit=$1 release=$2 script=$3
  local -a options=()
  shift 3
  while (($#)) && [[ $1 != -- ]]; do
    options+=("$1")
    shift
  done
  shift || return 64
  sudo systemd-run --quiet --no-ask-password --collect --unit="$unit" --expand-environment=no "${options[@]}" \
    "$BASH" -c "$script"'
status=$?
printf "%s %s\n" "$0" "$status" >/run/'"$unit"'.status
exit "$status"' "$release" "$@"
}

run_in_unit() {
  local unit=$1 release=$2 script=$3 started recorded
  shift 3
  started=$(date +%s)
  recorded_unit "$unit" "$release" "$script" --service-type=exec --wait -- "$@"
  sudo journalctl --no-pager -o cat _SYSTEMD_UNIT="$unit.service" --since "@$started" | tail -n 30 >&2
  recorded=$(recorded_status "$release" "$unit")
  [[ -n $recorded ]] || return 1
  printf 'deploy-unit-result %s %s end\n' "$release" "$recorded"
}

# A Tailscale SSH session that a tailscaled restart hangs up can end with exit
# status 1, so the transport's exit code cannot tell a failed unit from a
# dropped connection; only the status the unit recorded can.
# https://github.com/tailscale/tailscale/blob/v1.104.6/ssh/tailssh/tailssh.go (sshSession.run)
run_unit() {
  local unit=$1 deadline=$((SECONDS + $2)) script=$3 output result
  shift 3
  output=$({
    declare -f recorded_status recorded_unit run_in_unit
    printf '%s\n' 'run_in_unit "$@"'
  } | on_target "$unit" "$release_id" "$script" "$@") || true
  result=$(awk -v release="$release_id" \
    '$1 == "deploy-unit-result" && $2 == release && $3 ~ /^[0-9]+$/ && $4 == "end" && NF == 4 { print $3 }' \
    <<<"$output")
  if [[ -z $result ]]; then
    printf '%s gave no result over the connection. Waiting for the status it records.\n' "$unit" >&2
    result=$(wait_unit "$unit" "$deadline")
    case $result in
      running) return "$unit_running" ;;
      lost)
        printf '%s recorded no status.\n' "$unit" >&2
        return "$unit_lost"
        ;;
    esac
    printf '%s recorded status %s.\n' "$unit" "$result" >&2
  fi
  return "$result"
}

rollback_deadline() {
  printf 'The rollback timer starts the restore of the previous system at most %d seconds after the deploy armed it. journalctl -u deploy-rollback.service and /run/deploy-rollback.status on %s show the result.\n' \
    "$rollback_seconds" "$host" >&2
}

activate() {
  "$1/bin/switch-to-configuration" test
}

activate_with_rollback() {
  local activate_status=0 session_list
  local -a session=()

  session_list=$(session_services) || {
    printf '%s\n' 'Could not list the session services before activation. Nothing on the target changed.' >&2
    return 1
  }
  [[ -z $session_list ]] || mapfile -t session <<<"$session_list"
  # AccuracySec defaults to one minute, which would delay the rollback.
  {
    declare -f recorded_unit
    cat <<'REMOTE'
recorded_unit deploy-rollback "$1" "$2" --on-active="$3" --timer-property=AccuracySec=1s -- "$4"
REMOTE
  } | on_target "$release_id" "$(declare -f activate); activate \"\$@\"" "$rollback_seconds" "$previous_system" || {
    printf '%s\n' 'The rollback timer could not be armed, so nothing was activated.' >&2
    return 71
  }

  run_unit deploy-activate "$activation_seconds" "$(declare -f activate); activate \"\$@\"" "$new_system" ||
    activate_status=$?
  case $activate_status in
    "$unit_running")
      printf '%s\n' 'The activation reported no result in time.' >&2
      rollback_deadline
      return 1
      ;;
    "$unit_lost")
      printf '%s\n' 'The activation ended without a result.' >&2
      activate_status=1
      ;;
  esac
  if ((activate_status != 0)); then
    printf 'Activation failed (exit %d). Restoring the previous system now.\n' "$activate_status" >&2
    roll_back_now
    return "$activate_status"
  fi

  if ! confirm_target; then
    printf '%s\n' 'The target did not answer a fresh login.' >&2
    rollback_deadline
    return 1
  fi

  if ! check_session "${session[@]}"; then
    printf '%s\n' 'The desktop session broke. Restoring the previous system now.' >&2
    roll_back_now
    return 75
  fi
}

stop_rollback_timer() {
  local stop_status=0
  {
    declare -f recorded_status unit_ended
    cat <<'REMOTE'
set -euo pipefail

new=$1 release=$2 owner=$3 lock_free=$4
state_dir=$HOME/.local/state/nixos-config-deploy

exec 8>>"$state_dir/deploy.lock"
if flock -n 8; then
  exit "$lock_free"
fi
exec 8>&-
IFS= read -r holder <"$state_dir/deploy.owner" || holder=
if [[ $holder != "$owner since "* ]]; then
  printf 'Another deploy holds the lock on this host: %s\n' "${holder:-unknown}" >&2
  exit 77
fi

running_candidate() {
  [[ $(readlink -f /run/current-system) == "$new" ]] && unit_ended deploy-rollback.service &&
    [[ -z $(recorded_status "$release" deploy-rollback) ]]
}

running_candidate || { printf '%s\n' 'The rollback already ran. The target is not on the candidate.' >&2; exit 72; }
sudo systemctl stop deploy-rollback.timer
running_candidate || { printf '%s\n' 'The rollback ran during confirmation.' >&2; exit 72; }
REMOTE
  } | on_target "$new_system" "$release_id" "$lock_owner" "$lock_free" || stop_status=$?
  case $stop_status in
    0 | 72 | "$lock_free") return "$stop_status" ;;
    77)
      printf '%s\n' 'This deploy no longer holds the lock, so it leaves the rollback timer armed and the candidate running.' >&2
      rollback_deadline
      return 77
      ;;
  esac
  case $(target_state) in
    "$new_system inactive none") return 0 ;;
    "$new_system active none")
      printf '%s\n' 'The rollback timer could not be stopped, so it stays armed and the candidate keeps running.' >&2
      rollback_deadline
      return "$stop_status"
      ;;
    running)
      printf '%s\n' 'The state of the rollback timer could not be read, so it may still be armed. The candidate does not become the boot default.' >&2
      return "$stop_status"
      ;;
    *)
      printf '%s\n' 'The rollback ran during confirmation.' >&2
      return 72
      ;;
  esac
}

locked_stop() {
  local lock_status=0
  if ! lock_held; then
    retake_lock || lock_status=$?
    if ((lock_status != 0)); then
      printf '%s\n' 'Without the lock, this deploy leaves the rollback timer armed and the candidate running.' >&2
      rollback_deadline
      return "$lock_status"
    fi
  fi
  stop_rollback_timer
}

stop_rollback_timer_locked() {
  local stop_status=0
  locked_stop || stop_status=$?
  if ((stop_status == lock_free)); then
    printf 'The deploy lock on %s is free although its connection still runs. Waiting up to %d seconds for that connection to end.\n' \
      "$host" "$lock_end_seconds" >&2
    if await_lock_end; then
      stop_status=0
      locked_stop || stop_status=$?
    fi
  fi
  if ((stop_status == lock_free)); then
    printf 'This deploy could not take the lock on %s again, so it leaves the rollback timer armed and the candidate running.\n' "$host" >&2
    rollback_deadline
    return 1
  fi
  return "$stop_status"
}

install_entries() {
  local new=$1 profile=/nix/var/nix/profiles/system
  local previous_link previous_profile new_link restored=true verify=$new/etc/nixos-config-deploy/verify-boot-loaders
  PATH=$new/sw/bin
  previous_link=$(readlink "$profile")
  previous_profile=$(readlink -f "$profile")
  new_link=$previous_link
  if nix-env --profile "$profile" --set "$new"; then
    new_link=$(readlink "$profile")
    "$new/bin/switch-to-configuration" boot && { [[ ! -e $verify ]] || "$verify"; } && return 0
  fi
  printf '%s\n' 'Installing the boot entries failed. Restoring the previous boot default.'
  # Links are named system-<generation>-link.
  # Limine makes the newest generation the default, so the new one must go.
  if [[ $new_link != "$previous_link" && $(readlink -f "/nix/var/nix/profiles/$new_link") == "$new" ]]; then
    nix-env --profile "$profile" --switch-generation "${previous_link//[!0-9]/}" || restored=false
    nix-env --profile "$profile" --delete-generations "${new_link//[!0-9]/}" || restored=false
  fi
  if ! "$previous_profile/bin/switch-to-configuration" boot; then
    printf '%s\n' 'Reinstalling the previous boot entries failed too. Check the ESP before rebooting.'
  elif ! $restored; then
    printf '%s\n' 'Removing the new generation from the system profile failed, so Limine may still default to it. Check before rebooting.'
  else
    printf 'The boot default is %s again.\n' "$previous_profile"
  fi
  return 73
}

install_boot_entries() {
  local install_status=0
  run_unit deploy-boot "$install_seconds" "$(declare -f install_entries); install_entries \"\$@\"" "$new_system" ||
    install_status=$?
  case $install_status in
    0) return 0 ;;
    73) ;;
    *)
      printf '%s\n' \
        'The boot entry install reported no result. The system profile and the boot default may point at the candidate or at the previous system.' \
        "Read journalctl -u deploy-boot.service and readlink /nix/var/nix/profiles/system on $host before a reboot." >&2
      ;;
  esac
  [[ $action == boot ]] ||
    printf '%s\n' 'The candidate keeps running until the next reboot or deploy, and no rollback timer is armed.' >&2
  if ((install_status == 73)); then
    return 73
  fi
  return 76
}

promote_release() {
  on_target "$release_relative" "$new_system" <<'REMOTE'
set -euo pipefail

release_dir=$HOME/$1
new=$2
state_dir=$HOME/.local/state/nixos-config-deploy

printf 'system=%s\n' "$new" >>"$release_dir.source"
next_link=$state_dir/current.next.$$
trap 'rm -f -- "$next_link"' EXIT
ln -s -- "$release_dir" "$next_link"
mv -Tf -- "$next_link" "$state_dir/current"
trap - EXIT
printf 'Promoted release %s.\n' "$release_dir"
REMOTE
}

deploy() {
  build_candidate || return $?
  "${rsync_cmd[@]}" "$release_target/flake.lock" "$deploy_state_dir/flake.lock" || return $?
  local lock_blob
  lock_blob=$(git -C "$repo_dir" hash-object --path=flake.lock --stdin <"$deploy_state_dir/flake.lock") || return $?
  awk -F '\t' -v lock="$lock_blob" \
    'BEGIN { OFS = FS } $2 == "flake.lock" { $1 = lock } { print }' "$blobs" >"$blobs.final" || return $?
  "${rsync_cmd[@]}" "$blobs.final" "$release_target.blobs" || return $?
  ensure_lock || return $?
  if [[ $action != boot ]]; then
    activate_with_rollback || return $?
    stop_rollback_timer_locked || return $?
  fi
  if [[ $action != test ]]; then
    install_boot_entries || return $?
  fi
  promote_release
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
