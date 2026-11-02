#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=/dev/null
. "$(dirname "$0")/lib/rog-host.sh"

usage() {
  cat >&2 <<'EOF'
Usage: scripts/verify-nixos-rog.sh [-h] [--suspend [--while-in-use]] [--lan-ip ADDRESS] [--report FILE]

--suspend      also run three 20-second s2idle cycles with rtcwake and check
               that the kernel counts three successful suspends and that
               Wi-Fi, the RTX 4070 and the CPU limits come back. The SSH
               session drops and the screen goes dark while the laptop
               sleeps, so the cycles do not run while someone uses the laptop.
--while-in-use with --suspend, run the cycles even while a local session is in
               use. Alone it has no effect.
--lan-ip       the laptop's Wi-Fi address, to check that SSH does not answer
               on the LAN; tailscale0 is the only way in.
--report FILE  where to write the JSON report (default: a timestamped file
               under ~/.local/state/nixos-config-verify/). The report's
               revision and dirty fields name the revision the laptop runs,
               as scripts/affected-hosts.sh --running reads it ("unknown"
               and null when the laptop holds no deploy or upgrade record);
               checkout and checkout_dirty name this checkout.

Every run switches the laptop through power-saver, balanced and performance,
for a few seconds each, to check that the fan curves, asus-armoury limits and
CPU limits follow the profile, and then sets the original profile again.

The checks that need a person at the laptop (booting Windows, the recovery
entry and an older generation from the Limine menu, the HDMI picture) are
listed in the report as manual.

The facts the checks expect (the NVIDIA driver version, the Wi-Fi interface,
the low-battery threshold, the CPU temperature limit and top clock of each
profile, the fan curves and asus-armoury limits of each platform profile, the
Plasma panel widgets and KWin effects of each Plasma look, the microphone node
and the HushMic model) come from
/etc/oruc/verify-facts, which the deployed system writes
(nixosModules/verify-facts.nix). The Plasma checks use the look
that plasma-look prints as active, which is the stored look when it still
exists and the default look otherwise. The KWin effects are checked only in
a Plasma session that started after the current system and the last
plasma-look; an older session is listed as manual.

After a panel build from the current system's panel script, the panel file
must hold every widget setting of the look's panels, which the system writes
to /etc/oruc/verify-plasma-panels/LOOK.json.
After an older build the check is listed as manual. Each dock launcher in that file must name a desktop file
that the Plasma session can find. Each panel widget's General icon setting,
or the default in its main.xml file, must name an icon that the icon theme
holds. The OLED pixel shift must hold no
guard that a failed shift left, and its timer must run in a Plasma session.

Exit status: 0 when no check fails (the manual checks are for a person to
do), 1 when one fails, 64 for a usage error.
EOF
}

octet='(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])'
suspend=false
while_in_use=false
lan_ip=
report=
while (($# > 0)); do
  case $1 in
    --suspend) suspend=true ;;
    --while-in-use) while_in_use=true ;;
    --lan-ip | --report)
      if (($# < 2)); then
        usage
        exit 64
      fi
      if [[ $1 == --lan-ip ]]; then
        if [[ ! $2 =~ ^$octet(\.$octet){3}$ ]]; then
          usage
          exit 64
        fi
        lan_ip=$2
      else
        report=$2
      fi
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      usage
      exit 64
      ;;
  esac
  shift
done

repo_dir=$(cd "$(dirname "$0")/.." && pwd)
stamp=$(date -u +%Y%m%dT%H%M%SZ)
if [[ -z $report ]]; then
  report=$HOME/.local/state/nixos-config-verify/nixos-rog-$stamp.json
fi
mkdir -p -- "$(dirname "$report")"
results=$(mktemp)
work=$(mktemp -d)
record() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >>"$results"; }

revision=unknown
dirty=null
checkout=$(git -C "$repo_dir" rev-parse --short=12 HEAD 2>/dev/null || echo unknown)
checkout_dirty=false
[[ -z $(git -C "$repo_dir" status --porcelain 2>/dev/null) ]] || checkout_dirty=true

write_report() {
  jq -Rn --arg host "$ROG_HOST" --arg time "$stamp" --arg revision "$revision" --argjson dirty "$dirty" \
    --arg checkout "$checkout" --argjson checkout_dirty "$checkout_dirty" '
    [inputs | split("\t") | {name: .[0], status: .[1], detail: .[2]}] as $checks
    | {host: $host, time: $time, revision: $revision, dirty: $dirty,
       checkout: $checkout, checkout_dirty: $checkout_dirty, checks: $checks,
       failed: [$checks[] | select(.status == "fail") | .name]}' <"$results" >"$report"
}

reported=false
finish() {
  local status=$?
  if [[ $reported == false ]]; then
    record verify-script fail "the script stopped early with exit $status; the checks before it are in this report"
    write_report && printf 'Report: %s\n' "$report"
  fi
  rm -rf -- "$results" "$work"
}
trap finish EXIT
rog_pick_host

running=$({
  cat "$repo_dir/scripts/lib/running-revision.sh"
  echo running_revision
} | ssh "${SSH_OPTS[@]}" "$ROG_HOST" bash -s || true)
read -r running_sha running_dirty _ <<<"$running" || true
if [[ -n $running_sha ]]; then
  revision=${running_sha:0:12}
  dirty=false
  [[ $running_dirty != true ]] || dirty=true
fi

plasma_look=$(ssh "${SSH_OPTS[@]}" "$ROG_HOST" plasma-look 2>/dev/null | sed -n 's/^active: //p' || true)
if [[ ! $plasma_look =~ ^[a-z0-9]+$ ]]; then
  record plasma-look fail "plasma-look on $ROG_HOST printed no active look; the Plasma checks cannot pick their facts"
  plasma_look=none
fi

remote_prelude=$(
  printf 'plasma_look=%s\n' "$plasma_look"
  cat <<'PRELUDE'
facts=/etc/oruc/verify-facts
if [[ ! -r $facts ]]; then
  exit 66
fi
. "$facts"
for fact in low_battery_percent nvidia_version wifi \
  cpu_temp_limit_power_saver cpu_temp_limit_balanced cpu_temp_limit_performance \
  cpu_max_khz_power_saver cpu_max_khz_balanced cpu_max_khz_performance \
  fan_temps_quiet_cpu fan_pwms_quiet_cpu armoury_ac_quiet_ppt_pl1_spl mic_node hushmic_model; do
  if [[ -z ${!fact:-} ]]; then
    exit 66
  fi
done
plasma_look_file=$HOME/.local/state/oruc/plasma-look
if [[ $plasma_look =~ ^[a-z0-9]+$ ]]; then
  widgets_fact=plasma_widgets_$plasma_look
  effects_fact=kwin_effects_$plasma_look
  plasma_widgets=${!widgets_fact:-}
  kwin_effects=${!effects_fact:-}
fi
cpu_limits() {
  local temp
  temp=$(sudo ryzenadj -i | awk -F'|' '/THM LIMIT CORE/ {printf "%d", $3}')
  printf '%s/%s\n' "$temp" "$(</sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq)"
}
expected_cpu_limits() {
  local temp=cpu_temp_limit_${1//-/_} max=cpu_max_khz_${1//-/_}
  max=${!max}
  if [[ $max == top ]]; then
    max=$(</sys/devices/system/cpu/cpufreq/policy0/cpuinfo_max_freq)
  fi
  printf '%s/%s\n' "${!temp}" "$max"
}
find_nvidia() {
  local dev
  for dev in /sys/bus/pci/devices/*; do
    if [[ $(<"$dev/vendor") == 0x10de && $(<"$dev/class") == 0x030* ]]; then
      printf '%s\n' "${dev##*/}"
      return
    fi
  done
}
PRELUDE
)

remote() {
  {
    printf '%s\n' "$remote_prelude"
    cat
  } | ssh "${SSH_OPTS[@]}" "$ROG_HOST" bash -s
}

remote_checks() {
  cat "$repo_dir/scripts/verify-rog/prelude.sh" \
    "$repo_dir/scripts/verify-rog/power.sh" \
    "$repo_dir/scripts/verify-rog/network.sh" \
    "$repo_dir/scripts/verify-rog/audio.sh" \
    "$repo_dir/scripts/verify-rog/desktop.sh" \
    "$repo_dir/scripts/verify-rog/gpu.sh" | remote
}

widget_icon_tsv=
widget_icon_ok=0
panels_json=/etc/oruc/verify-plasma-panels/$plasma_look.json
have_panels=false
have_defaults=false
mkdir -p "$work/widget-defaults"
# shellcheck disable=SC2029 # panels_json holds only a fixed path and a checked look name
if ssh "${SSH_OPTS[@]}" "$ROG_HOST" cat "$panels_json" >"$work/expected.json" 2>/dev/null; then
  have_panels=true
fi
if [[ $have_panels == true ]] && ssh "${SSH_OPTS[@]}" "$ROG_HOST" bash -s <<'REMOTE' | tar -x -C "$work/widget-defaults"
set -euo pipefail
out=$(mktemp -d)
trap 'rm -rf -- "$out"' EXIT
for root in /run/current-system/sw "/etc/profiles/per-user/$USER"; do
  for file in "$root"/share/plasma/plasmoids/*/contents/config/main.xml; do
    [[ -e $file ]] || continue
    widget=${file#"$root/share/plasma/plasmoids/"}
    widget=${widget%%/*}
    mkdir -p "$out/$widget"
    cat "$file" >"$out/$widget/main.xml"
  done
done
tar -c -C "$out" .
REMOTE
then
  have_defaults=true
fi
if [[ $have_defaults == true ]] &&
  widget_icon_tsv=$(python3 -I "$repo_dir/scripts/lib/plasma-panel-settings.py" --icons "$work/expected.json" "$work/widget-defaults"); then
  widget_icon_ok=1
fi
remote_prelude+=$'\n'"widget_icon_ok=$widget_icon_ok"$'\n'"widget_icon_rows=$(printf '%q' "$widget_icon_tsv")"

status=0
remote_checks >>"$results" || status=$?
case $status in
  0) ;;
  66) record verify-facts fail "/etc/oruc/verify-facts is missing on $ROG_HOST or lacks a fact the checks need; deploy a system that writes it" ;;
  *) record remote-checks fail "SSH to $ROG_HOST failed (exit $status)" ;;
esac

build=$(
  # shellcheck disable=SC2029 # panels_json holds only a fixed path and a checked look name
  ssh "${SSH_OPTS[@]}" "$ROG_HOST" "bash -s -- $panels_json" <<'REMOTE' || true
manager=$HOME/.local/share/plasma-manager
if [[ ! -r $1 ]]; then
  echo none
elif [[ $(sha256sum "$manager/data/desktop_script_panels.js" 2>/dev/null) == "$(cat "$manager/last_run_desktop_script_panels" 2>/dev/null)" ]]; then
  echo current
else
  echo old
fi
REMOTE
)
case $build in
  none) record plasma-panel-settings manual "$ROG_HOST has no $panels_json; deploy a system that writes it, then rerun" ;;
  old) record plasma-panel-settings manual "the panels were not built from this system's panel script; log out and in, or run scripts/panels-rebuild-on-rog.sh, then rerun" ;;
  current)
    compared=0
    if [[ $have_defaults == true ]] &&
      ssh "${SSH_OPTS[@]}" "$ROG_HOST" cat .config/plasma-org.kde.plasma.desktop-appletsrc >"$work/appletsrc"; then
      differences=$(python3 -I "$repo_dir/scripts/lib/plasma-panel-settings.py" "$work/expected.json" "$work/appletsrc" "$work/widget-defaults" 2>&1) || compared=$?
    else
      compared=255
    fi
    case $compared in
      0) record plasma-panel-settings pass "the panel file holds every setting of the $plasma_look look's panels" ;;
      1) record plasma-panel-settings fail "${differences//$'\n'/; }. A change made in Plasma lasts only until the next panel build; ask Omer whether to write it into plasma-panels.nix before you rebuild the panels" ;;
      *) record plasma-panel-settings fail "could not compare the panel file (exit $compared): ${differences:-copy from $ROG_HOST failed}" ;;
    esac
    ;;
  *) record plasma-panel-settings fail "could not read the panel build state on $ROG_HOST" ;;
esac

launcher_ids=
if [[ $have_panels == false ]]; then
  record dock-launchers-installed manual "could not copy $panels_json from $ROG_HOST; deploy a system that writes it, then rerun"
elif ! launcher_ids=$(python3 -I "$repo_dir/scripts/lib/plasma-panel-settings.py" --launchers "$work/expected.json"); then
  record dock-launchers-installed fail "could not read the launchers of $panels_json"
elif [[ -z $launcher_ids ]]; then
  record dock-launchers-installed manual "no applications: launcher in $ROG_HOST's $panels_json"
else
  mapfile -t launchers <<<"$launcher_ids"
  launcher_status=0
  missing=$(
    # shellcheck disable=SC2029 # printf %q quotes the arguments for the remote shell
    ssh "${SSH_OPTS[@]}" "$ROG_HOST" "bash -s -- $(printf '%q ' "${launchers[@]}")" <<'REMOTE'
environment=$(systemctl --user show-environment) || exit 4
dirs=$(sed -n 's/^XDG_DATA_DIRS=//p' <<<"$environment")
[[ -n $dirs ]] || exit 3
data_home=$(sed -n 's/^XDG_DATA_HOME=//p' <<<"$environment")
IFS=: read -ra search <<<"${data_home:-$HOME/.local/share}:$dirs"
declare -A ids=()
for dir in "${search[@]}"; do
  [[ -d $dir/applications ]] || continue
  while IFS= read -r -d '' path; do
    ids[${path//\//-}]=1
  done < <(find -L "$dir/applications" -name '*.desktop' -type f -printf '%P\0' 2>/dev/null)
done
for id; do
  [[ -n ${ids[$id]:-} ]] || printf '%s\n' "$id"
done
REMOTE
  ) || launcher_status=$?
  case $launcher_status in
    0) if [[ -z $missing ]]; then
      record dock-launchers-installed pass "${#launchers[@]} desktop files found"
    else
      record dock-launchers-installed fail "no desktop file for ${missing//$'\n'/, }; install the app or drop its launcher from oruc.plasma.dockLaunchers in machines/nixos-rog/home.nix"
    fi ;;
    3) record dock-launchers-installed manual "the user manager on $ROG_HOST has no XDG_DATA_DIRS; log in to Plasma, then rerun" ;;
    4) record dock-launchers-installed fail "systemctl --user show-environment failed on $ROG_HOST" ;;
    *) record dock-launchers-installed fail "SSH to $ROG_HOST failed (exit $launcher_status)" ;;
  esac
fi

if [[ -n $lan_ip ]]; then
  probe=0
  # shellcheck disable=SC2016 # the inner shell expands $1
  probe_error=$(LC_ALL=C timeout 5 bash -c 'exec 3<>"/dev/tcp/$1/22"' _ "$lan_ip" 2>&1) || probe=$?
  probe_error=${probe_error//$'\n'/ }
  if ((probe == 0)); then
    record lan-ssh-port fail "TCP 22 answers on $lan_ip"
  elif ((probe == 124)); then
    record lan-ssh-port pass "TCP 22 on $lan_ip times out"
  elif [[ $probe_error == *'Connection refused'* ]]; then
    record lan-ssh-port pass "TCP 22 on $lan_ip refuses connections"
  else
    record lan-ssh-port fail "probe of $lan_ip:22 failed (exit $probe): $probe_error"
  fi
fi

if [[ $suspend == true && $while_in_use == false ]]; then
  if ! ssh "${SSH_OPTS[@]}" "$ROG_HOST" 'bash -s' <<'REMOTE'
set -euo pipefail
id=$(loginctl show-seat seat0 -p ActiveSession --value)
[[ -n $id ]] || exit 0
session=$(loginctl show-session "$id" -p Class -p Remote -p IdleHint -p LockedHint | sort | paste -sd ' ')
[[ $session != 'Class=user IdleHint=no LockedHint=no Remote=no' ]]
REMOTE
  then
    record suspend-three-cycles fail \
      "not suspended: a local session is in use or could not be read; lock the screen or rerun with --while-in-use"
    suspend=false
  fi
fi

suspend_cycles() {
  local before after_resume reason tries=30 interval=10
  if ! before=$(ssh "${SSH_OPTS[@]}" "$ROG_HOST" \
    'cat /sys/power/suspend_stats/success; sudo -n systemd-run --quiet --collect --unit=verify-suspend sh -c "for i in 1 2 3; do rtcwake -m freeze -s 20 || exit 1; sleep 20; done"' 2>"$work/suspend-start.err"); then
    record suspend-three-cycles fail "could not start the suspend cycles on $ROG_HOST: $(paste -sd ' ' "$work/suspend-start.err")"
    return
  fi
  after_resume=$(
    cat <<'REMOTE'
set -euo pipefail
missing() { echo "$1"; exit 1; }
suspends=$(( $(cat /sys/power/suspend_stats/success) - before ))
(( suspends >= 3 )) || missing "$suspends of 3 suspends succeeded"
[[ $(cat "/sys/class/net/$wifi/operstate") == up ]] || missing "Wi-Fi $wifi is not up"
[[ -n $(find_nvidia) ]] || missing "the RTX 4070 is missing"
[[ $(cpu_limits) == "$(expected_cpu_limits "$(powerprofilesctl get)")" ]] || missing "the CPU limits differ from the profile's"
REMOTE
  )
  for ((try = 1; try <= tries; try++)); do
    sleep "$interval"
    if reason=$(printf 'before=%s\n%s\n' "$before" "$after_resume" | remote 2>/dev/null); then
      record suspend-three-cycles pass "3 successful suspends, Wi-Fi up, RTX 4070 present, CPU limits of the profile"
      return
    fi
  done
  record suspend-three-cycles fail "after $((tries * interval)) s: ${reason:-no answer from $ROG_HOST}"
}

if [[ $suspend == true ]]; then
  suspend_cycles
fi

for manual in \
  "boot-windows-from-limine:Boot the Limine /Windows entry and reach the Windows login" \
  "boot-recovery-entry:Boot the recovery entry, reach a console, Wi-Fi and SSH, then boot the default again" \
  "boot-previous-generation:Boot the previous NixOS generation from Limine, then the newest again" \
  "hdmi-picture:Plug in an HDMI display and check the picture"; do
  record "${manual%%:*}" manual "${manual#*:}"
done

write_report
reported=true

jq -r '.checks[] | "\(.status)\t\(.name)\t\(.detail)"' "$report"
printf 'Report: %s\n' "$report"
if jq -e '.failed | length > 0' "$report" >/dev/null; then
  exit 1
fi
