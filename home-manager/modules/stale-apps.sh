#!/usr/bin/env bash
shopt -s nullglob

profile=/etc/profiles/per-user/$USER
state_dir=${XDG_STATE_HOME:-$HOME/.local/state}/stale-apps
notified_file=$state_dir/notified

store_path() {
  [[ $1 =~ ^/nix/store/[^/]+ ]] && printf '%s\n' "${BASH_REMATCH[0]}"
}

package_name() {
  local name=${1#/nix/store/*-}
  name=${name%.desktop}
  name=${name%%-[0-9]*}
  printf '%s\n' "${name%-unwrapped}"
}

declare -A apps=()
for desktop in "$profile"/share/applications/*.desktop; do
  apps[$(package_name "$(store_path "$(readlink -f "$desktop")")")]=1
done

generations=()
for link in /nix/var/nix/profiles/system-*-link/etc/profiles/per-user/"$USER"; do
  generations+=("$(readlink -f "$link")")
done
earlier_paths=$(nix-store --query --requisites "${generations[@]}")
current_paths=$(nix-store --query --requisites "$(readlink -f "$profile")")
declare -A replaced=()
while read -r path; do
  replaced[$path]=1
done <<<"$earlier_paths"
while read -r path; do
  unset "replaced[$path]"
done <<<"$current_paths"

declare -A stale=()
for proc in /proc/[0-9]*; do
  exe=$(readlink "$proc/exe" 2>/dev/null) || continue
  exe_path=$(store_path "${exe% (deleted)}") || continue
  used=("$exe_path")
  case $(package_name "$exe_path") in
    bash | bash-interactive | electron)
      mapfile -d '' -t args 2>/dev/null <"$proc/cmdline" || continue
      for arg in "${args[@]:1}"; do
        if path=$(store_path "$arg"); then
          used+=("$path")
        fi
      done
      ;;
  esac
  for path in "${used[@]}"; do
    if [[ ! -v replaced[$path] ]]; then
      continue
    fi
    name=$(package_name "$path")
    if [[ -v apps[$name] ]]; then
      stale[$path]=$name
    fi
  done
done

declare -A notified=()
if [[ -f $notified_file ]]; then
  while read -r path; do
    notified[$path]=1
  done <"$notified_file"
fi

declare -A new=()
for path in "${!stale[@]}"; do
  if [[ ! -v notified[$path] ]]; then
    new[${stale[$path]}]=1
  fi
done

if ((${#new[@]})); then
  names=$(printf '%s\n' "${!new[@]}" | sort | paste -sd ',')
  notify-send --app-name=Updates --icon=system-software-update \
    "Restart to use the update" "${names//,/, }"
fi

mkdir -p "$state_dir"
if ((${#stale[@]})); then
  printf '%s\n' "${!stale[@]}"
fi >"$notified_file.tmp"
mv "$notified_file.tmp" "$notified_file"
