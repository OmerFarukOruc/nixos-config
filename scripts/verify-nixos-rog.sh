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
               under ~/.local/state/nixos-config-verify/).

Every run switches the laptop through power-saver, balanced and performance,
for a few seconds each, to check that the fan curves, asus-armoury limits and
CPU limits follow the profile, and then sets the original profile again.

The checks that need a person at the laptop (booting Windows, the recovery
entry and an older generation from the Limine menu, the HDMI picture) are
listed in the report as manual.

The facts the checks expect (the NVIDIA driver version, the Wi-Fi interface,
the low-battery threshold, the CPU temperature limit and top clock of each
profile, the fan curves and asus-armoury limits of each platform profile, the
Plasma panel widgets and KWin effects of each Plasma look) come from
/etc/oruc/verify-facts, which the deployed system writes
(nixosModules/verify-facts.nix). The Plasma checks use the look that
plasma-look stored, or the default look. The KWin effects are checked only in
a Plasma session that started after the current system and the last
plasma-look; an older session is listed as manual.

After a panel build from the current system's panel script, the panel file
must hold every widget setting of the look's panels with the stored scheme,
which the system writes to /etc/oruc/verify-plasma-panels/LOOK_SCHEME.json.
After an older build the check is listed as manual. Each dock launcher in that file must name a desktop file
that the Plasma session can find. Each panel widget's General icon setting,
or the default in its main.xml file, must name an icon that the icon theme
holds. The OLED pixel shift must hold no
guard that a failed shift left, and its timer must run in a Plasma session.

Exit status: 0 when no check fails (the manual checks are for a person to
do), 1 when one fails, 64 for a usage error.
EOF
}

host=nixos-rog
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

rog_pick_host
repo_dir=$(cd "$(dirname "$0")/.." && pwd)
stamp=$(date -u +%Y%m%dT%H%M%SZ)
if [[ -z $report ]]; then
  report=$HOME/.local/state/nixos-config-verify/nixos-rog-$stamp.json
fi
mkdir -p -- "$(dirname "$report")"
ssh_opts=(-o ConnectTimeout=15 -o BatchMode=yes)
results=$(mktemp)
work=$(mktemp -d)
trap 'rm -rf -- "$results" "$work"' EXIT

record() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >>"$results"; }

remote_prelude=$(
  cat <<'PRELUDE'
facts=/etc/oruc/verify-facts
if [[ ! -r $facts ]]; then
  exit 66
fi
. "$facts"
for fact in low_battery_percent nvidia_version wifi \
  cpu_temp_limit_power_saver cpu_temp_limit_balanced cpu_temp_limit_performance \
  cpu_max_khz_power_saver cpu_max_khz_balanced cpu_max_khz_performance \
  fan_temps_quiet_cpu fan_pwms_quiet_cpu armoury_ac_quiet_ppt_pl1_spl; do
  if [[ -z ${!fact:-} ]]; then
    exit 66
  fi
done
plasma_look_file=$HOME/.local/state/oruc/plasma-look
plasma_look=$(cat "$plasma_look_file" 2>/dev/null || echo "${plasma_look_default:-}")
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
  } | ssh "${ssh_opts[@]}" "$host" bash -s
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
icon_plasma_look=$(ssh "${ssh_opts[@]}" "$host" \
  'cat .local/state/oruc/plasma-look 2>/dev/null || sed -n "s/^plasma_look_default=//p" /etc/oruc/verify-facts' || true)
[[ $icon_plasma_look =~ ^[a-z0-9]+$ ]] || icon_plasma_look=none
icon_scheme=$(ssh "${ssh_opts[@]}" "$host" \
  'cat .local/state/oruc/scheme 2>/dev/null || sed -n "s/^scheme_default=//p" /etc/oruc/verify-facts' || true)
[[ $icon_scheme =~ ^[a-z0-9-]+$ ]] || icon_scheme=none
icon_panels=/etc/oruc/verify-plasma-panels/${icon_plasma_look}_$icon_scheme.json
mkdir -p "$work/widget-defaults"
# shellcheck disable=SC2029 # icon_panels holds only a fixed path and a checked look name
if ssh "${ssh_opts[@]}" "$host" cat "$icon_panels" >"$work/icons-panels.json" 2>/dev/null &&
  ssh "${ssh_opts[@]}" "$host" bash -s <<'REMOTE' | tar -x -C "$work/widget-defaults"
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
  widget_icon_tsv=$(python3 -I -B -c '
import json, os, sys
from importlib.machinery import SourceFileLoader
mod = SourceFileLoader("panel_settings", sys.argv[1]).load_module()
for panel in json.load(open(sys.argv[2])):
    for widget in panel["widgets"]:
        icon = ((widget.get("config") or {}).get("General") or {}).get("icon") or ""
        if not icon:
            xml = os.path.join(sys.argv[3], widget["name"], "main.xml")
            if os.path.isfile(xml):
                icon = mod.icon_default(xml)
        if icon:
            name = widget["name"]
            print(name + "\t" + icon)
' "$repo_dir/scripts/lib/plasma-panel-settings.py" "$work/icons-panels.json" "$work/widget-defaults")
  widget_icon_ok=1
fi
remote_prelude+=$'\n'"widget_icon_ok=$widget_icon_ok"$'\n'"widget_icon_rows=$(printf '%q' "$widget_icon_tsv")"

status=0
remote_checks >>"$results" || status=$?
case $status in
  0) ;;
  66) record verify-facts fail "/etc/oruc/verify-facts is missing on $host or lacks a fact the checks need; deploy a system that writes it" ;;
  *) record remote-checks fail "SSH to $host failed (exit $status)" ;;
esac

plasma_look=$(ssh "${ssh_opts[@]}" "$host" \
  'cat .local/state/oruc/plasma-look 2>/dev/null || sed -n "s/^plasma_look_default=//p" /etc/oruc/verify-facts' || true)
[[ $plasma_look =~ ^[a-z0-9]+$ ]] || plasma_look=none
scheme=$(ssh "${ssh_opts[@]}" "$host" \
  'cat .local/state/oruc/scheme 2>/dev/null || sed -n "s/^scheme_default=//p" /etc/oruc/verify-facts' || true)
[[ $scheme =~ ^[a-z0-9-]+$ ]] || scheme=none
panels_json=/etc/oruc/verify-plasma-panels/${plasma_look}_$scheme.json

build=$(
  # shellcheck disable=SC2029 # panels_json holds only a fixed path and a checked look name
  ssh "${ssh_opts[@]}" "$host" "bash -s -- $panels_json" <<'REMOTE' || true
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
  none) record plasma-panel-settings manual "$host has no $panels_json; deploy a system that writes it, then rerun" ;;
  old) record plasma-panel-settings manual "the panels were not built from this system's panel script; log out and in, or run scripts/panels-rebuild-on-rog.sh, then rerun" ;;
  current)
    compared=0
    mkdir -p "$work/widget-defaults"
    # shellcheck disable=SC2029 # panels_json holds only a fixed path and a checked look name
    if ssh "${ssh_opts[@]}" "$host" cat "$panels_json" >"$work/expected.json" &&
      ssh "${ssh_opts[@]}" "$host" cat .config/plasma-org.kde.plasma.desktop-appletsrc >"$work/appletsrc" &&
      ssh "${ssh_opts[@]}" "$host" bash -s <<'REMOTE' | tar -x -C "$work/widget-defaults"
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
      differences=$(python3 -I "$repo_dir/scripts/lib/plasma-panel-settings.py" "$work/expected.json" "$work/appletsrc" "$work/widget-defaults" 2>&1) || compared=$?
    else
      compared=255
    fi
    case $compared in
      0) record plasma-panel-settings pass "the panel file holds every setting of the $plasma_look look's panels" ;;
      1) record plasma-panel-settings fail "${differences//$'\n'/; }. A change made in Plasma lasts only until the next panel build; ask Omer whether to write it into plasma-panels.nix before you rebuild the panels" ;;
      *) record plasma-panel-settings fail "could not compare the panel file (exit $compared): ${differences:-copy from $host failed}" ;;
    esac
    ;;
  *) record plasma-panel-settings fail "could not read the panel build state on $host" ;;
esac

launchers=()
# shellcheck disable=SC2029 # panels_json holds only a fixed path and a checked look name
if ssh "${ssh_opts[@]}" "$host" cat "$panels_json" >"$work/launchers.json" 2>/dev/null; then
  mapfile -t launchers < <(python3 -I -c '
import json, sys
for panel in json.load(open(sys.argv[1])):
    for widget in panel["widgets"]:
        for launcher in ((widget.get("config") or {}).get("General") or {}).get("launchers") or []:
            if launcher.startswith("applications:"):
                print(launcher.removeprefix("applications:"))
' "$work/launchers.json")
fi
if ((${#launchers[@]} == 0)); then
  record dock-launchers-installed manual "no applications: launcher in $host's $panels_json"
else
  launcher_status=0
  missing=$(
    # shellcheck disable=SC2029 # printf %q quotes the arguments for the remote shell
    ssh "${ssh_opts[@]}" "$host" "bash -s -- $(printf '%q ' "${launchers[@]}")" <<'REMOTE'
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
    3) record dock-launchers-installed manual "the user manager on $host has no XDG_DATA_DIRS; log in to Plasma, then rerun" ;;
    4) record dock-launchers-installed fail "systemctl --user show-environment failed on $host" ;;
    *) record dock-launchers-installed fail "SSH to $host failed (exit $launcher_status)" ;;
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
  if ! ssh "${ssh_opts[@]}" "$host" 'bash -s' <<'REMOTE'
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

if [[ $suspend == true ]]; then
  before=$(ssh "${ssh_opts[@]}" "$host" \
    'cat /sys/power/suspend_stats/success; sudo systemd-run --quiet --collect --unit=verify-suspend sh -c "for i in 1 2 3; do rtcwake -m freeze -s 20 || exit 1; sleep 20; done"')
  after_resume=$(
    cat <<'REMOTE'
set -euo pipefail
test "$(( $(cat /sys/power/suspend_stats/success) - before ))" -ge 3
test "$(cat "/sys/class/net/$wifi/operstate")" = up
test -n "$(find_nvidia)"
test "$(cpu_limits)" = "$(expected_cpu_limits "$(powerprofilesctl get)")"
REMOTE
  )
  resumed=false
  for _ in {1..30}; do
    sleep 10
    if printf 'before=%s\n%s\n' "$before" "$after_resume" | remote 2>/dev/null; then
      resumed=true
      break
    fi
  done
  if [[ $resumed == true ]]; then
    record suspend-three-cycles pass "3 successful suspends, Wi-Fi up, RTX 4070 present, CPU limits of the profile"
  else
    record suspend-three-cycles fail "fewer than 3 successful suspends, or Wi-Fi, the RTX 4070 or the CPU limits missing afterwards"
  fi
fi

for manual in \
  "boot-windows-from-limine:Boot the Limine /Windows entry and reach the Windows login" \
  "boot-recovery-entry:Boot the recovery entry, reach a console, Wi-Fi and SSH, then boot the default again" \
  "boot-previous-generation:Boot the previous NixOS generation from Limine, then the newest again" \
  "hdmi-picture:Plug in an HDMI display and check the picture"; do
  record "${manual%%:*}" manual "${manual#*:}"
done

jq -Rn --arg host "$host" --arg time "$stamp" \
  --arg revision "$(git -C "$repo_dir" rev-parse --short=12 HEAD)" '
  [inputs | split("\t") | {name: .[0], status: .[1], detail: .[2]}] as $checks
  | {host: $host, time: $time, revision: $revision, checks: $checks,
     failed: [$checks[] | select(.status == "fail") | .name]}' <"$results" >"$report"

jq -r '.checks[] | "\(.status)\t\(.name)\t\(.detail)"' "$report"
printf 'Report: %s\n' "$report"
if jq -e '.failed | length > 0' "$report" >/dev/null; then
  exit 1
fi
