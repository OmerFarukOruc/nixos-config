#!/usr/bin/env bash
# Checks a running nixos-rog from fedora-desktop and writes a JSON report.
# Rerun it after any deploy to the laptop and compare the reports.
set -euo pipefail

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
Plasma panel widgets and KWin effects) come from /etc/oruc/verify-facts, which
the deployed system writes (nixosModules/verify-facts.nix). The KWin
effects are checked only in a Plasma session that started after the current
system; an older session is listed as manual.

After a panel build from the current system's panel script, the panel file
must hold every widget setting in plasma-panels.nix, which the system writes
to /etc/oruc/verify-plasma-panels.json. After an older build the check is
listed as manual.

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

# One line per check: name<TAB>pass|fail|manual<TAB>detail
record() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >>"$results"; }

# Facts the remote checks expect, from the configuration the host runs.
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
# The CPU temperature limit in the SMU and the top clock of policy0, a full
# Zen 5 core, as TEMP/KHZ.
cpu_limits() {
  local temp
  temp=$(sudo ryzenadj -i | awk -F'|' '/THM LIMIT CORE/ {printf "%d", $3}')
  printf '%s/%s\n' "$temp" "$(</sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq)"
}
# The TEMP/KHZ that machines/nixos-rog/cpu-limits.nix sets for PROFILE.
expected_cpu_limits() {
  local temp=cpu_temp_limit_${1//-/_} max=cpu_max_khz_${1//-/_}
  max=${!max}
  if [[ $max == top ]]; then
    max=$(</sys/devices/system/cpu/cpufreq/policy0/cpuinfo_max_freq)
  fi
  printf '%s/%s\n' "${!temp}" "$max"
}
# The NVIDIA display controller, found through sysfs because pciutils is not installed.
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

# Runs a remote script after the shared facts and helpers.
remote() {
  {
    printf '%s\n' "$remote_prelude"
    cat
  } | ssh "${ssh_opts[@]}" "$host" bash -s
}

remote_checks() {
  remote <<'REMOTE'
set -uo pipefail
report() { printf '%s\t%s\t%s\n' "$1" "$2" "$3"; } # report NAME STATUS DETAIL
check() { # check NAME DETAIL CONDITION...
  local name=$1 detail=$2; shift 2
  if "$@" >/dev/null 2>&1; then
    report "$name" pass "$detail"
  else
    report "$name" fail "$detail"
  fi
}
armoury=/sys/class/firmware-attributes/asus-armoury/attributes
nvidia_dev=$(find_nvidia)

check hostname "$(hostname)" test "$(hostname)" = nixos-rog
check sudo-without-password "sudo -n true" sudo -n true
check wifi-interface "$wifi is up" test "$(cat "/sys/class/net/$wifi/operstate" 2>/dev/null)" = up

limine_conf=$(sudo cat /boot/limine/limine.conf 2>/dev/null)
entries=$(grep -E '^ *//?[^ ]' <<<"$limine_conf" | sed 's/^ *//' | tr '\n' ';')
check limine-windows-entry "$entries" grep -q '^/Windows$' <<<"$limine_conf"
check limine-nixos-entries "NixOS generations in limine.conf" grep -q 'Generation' <<<"$limine_conf"
free_mib=$(( $(df -B1 --output=avail /boot | tail -n 1) / 1048576 ))
check esp-free-1gib "${free_mib} MiB free on /boot" test "$free_mib" -ge 1024

scx_ops=$(cat /sys/kernel/sched_ext/root/ops 2>/dev/null)
check sched-ext-lavd "$scx_ops" test "${scx_ops%%_*}" = lavd
dgpu_disable=$(<"$armoury/dgpu_disable/current_value")
gpu_mux=$(<"$armoury/gpu_mux_mode/current_value")
check gpu-mode-hybrid "dgpu_disable=$dgpu_disable gpu_mux_mode=$gpu_mux" test "$dgpu_disable$gpu_mux" = 01
check rtx4070-on-pci "${nvidia_dev:-absent}" test -n "$nvidia_dev"
loaded_version=$(cat /sys/module/nvidia/version 2>/dev/null)
check nvidia-driver "${loaded_version:-not loaded}" test "$loaded_version" = "$nvidia_version"

# The daemon saves each profile change in its state file and starts in the
# saved profile, or in balanced without one, so the running profile is the
# one a reboot brings back.
profile=$(powerprofilesctl get)
ppd_state=$(systemctl is-active power-profiles-daemon)
saved=$(sed -n 's/^Profile=//p' /var/lib/power-profiles-daemon/state.ini 2>/dev/null)
check ppd-profile-kept "power-profiles-daemon is $ppd_state; saved ${saved:-nothing}, running $profile" \
  test "$ppd_state/${saved:-balanced}" = "active/$profile"
# The shell's power menu may pick any profile. Only low battery on battery
# requires one.
online=$(cat /sys/class/power_supply/ACAD/online)
capacity=$(cat /sys/class/power_supply/BAT1/capacity)
if [[ $online == 0 && $capacity -le $low_battery_percent ]]; then
  check ppd-profile "$profile on low battery (battery=$capacity%)" test "$profile" = power-saver
else
  check ppd-profile "$profile as chosen (AC=$online, battery=$capacity%)" test -n "$profile"
fi
# On AC the low-battery service undoes its own drop as soon as udev sees the
# charger, and removes its marker.
if [[ $online == 1 ]]; then
  check low-battery-undone "/run/oruc-low-battery/active absent on AC" test ! -e /run/oruc-low-battery/active
fi
# power-profiles-daemon turns boost off only in power-saver. It writes each
# CPU policy's boost file; the global cpufreq/boost stays 1.
expected_boost=1
[[ $profile == power-saver ]] && expected_boost=0
boost=$(sort -u /sys/devices/system/cpu/cpufreq/policy*/boost | tr '\n' ' ')
boost=${boost% }
check boost-per-profile "boost=$boost in $profile" test "$boost" = "$expected_boost"
# asusd writes the asus-armoury limits and the fan curves of the platform
# profile on each profile change, and the firmware applies the ppt_* limits:
# ryzenadj -i shows them as its STAPM and PPT limits. These checks switch to
# each profile and compare what reaches sysfs with the deployed config.
# The kernel keeps the curve it last sent to the firmware in the
# asus_custom_fan_curve hwmon, where pwmN_enable reads 1 while it applies.
curve_dir=
for dir in /sys/class/hwmon/hwmon*; do
  [[ $(<"$dir/name") == asus_custom_fan_curve ]] && curve_dir=$dir
done
power_source=dc
[[ $online == 1 ]] && power_source=ac
# asus-wmi numbers the fans pwm1 to pwm3 in this order.
fans=([1]=cpu [2]=gpu [3]=mid)
# Prints each fan whose live curve differs from the facts of platform profile $1.
fan_curve_diffs() {
  local n temps_fact pwms_fact temps pwms enable
  [[ -n $curve_dir ]] || { echo "no asus_custom_fan_curve hwmon"; return; }
  for n in "${!fans[@]}"; do
    temps_fact=fan_temps_${1}_${fans[n]} pwms_fact=fan_pwms_${1}_${fans[n]}
    temps=$(cat "$curve_dir"/pwm${n}_auto_point{1..8}_temp | paste -sd,)
    pwms=$(cat "$curve_dir"/pwm${n}_auto_point{1..8}_pwm | paste -sd,)
    enable=$(<"$curve_dir/pwm${n}_enable")
    [[ $temps == "${!temps_fact}" && $pwms == "${!pwms_fact}" && $enable == 1 ]] ||
      echo "$1 ${fans[n]} temps $temps pwms $pwms enable $enable, want ${!temps_fact} ${!pwms_fact} 1"
  done
}
# Prints each asus-armoury limit that differs from the facts of platform
# profile $1 on the current power source.
armoury_diffs() {
  local prefix=armoury_${power_source}_${1}_ fact attribute live
  for fact in ${!armoury_@}; do
    [[ $fact == "$prefix"* ]] || continue
    attribute=${fact#"$prefix"}
    live=$(<"$armoury/$attribute/current_value")
    [[ $live == "${!fact}" ]] || echo "$1 $attribute=$live, want ${!fact}"
  done
}
restore_profile() {
  sudo powerprofilesctl set "$profile" && [[ $(powerprofilesctl get) == "$profile" ]]
}
trap restore_profile EXIT HUP
platform=()
cpu=()
cpu_ok=true
fan_found=()
armoury_found=()
for target in power-saver balanced performance; do
  sudo powerprofilesctl set "$target" && sleep 1
  pp=$(</sys/firmware/acpi/platform_profile)
  platform+=("$target=$pp")
  # oruc-cpu-limits applies the limits after the profile change signal.
  want=$(expected_cpu_limits "$target")
  for _ in {1..5}; do
    got=$(cpu_limits)
    fan_diff=$(fan_curve_diffs "$pp")
    armoury_diff=$(armoury_diffs "$pp")
    [[ $got == "$want" && -z $fan_diff$armoury_diff ]] && break
    sleep 1
  done
  [[ $got == "$want" ]] || cpu_ok=false
  cpu+=("$target=$got/want=$want")
  [[ -z $fan_diff ]] || fan_found+=("${fan_diff//$'\n'/; }")
  [[ -z $armoury_diff ]] || armoury_found+=("${armoury_diff//$'\n'/; }")
done
if restore_profile; then
  trap - EXIT HUP
  printf 'power-profile-restored\tpass\t%s\n' "$profile"
else
  printf 'power-profile-restored\tfail\t%s\n' "could not set $profile again; the laptop may stay in another profile"
fi
check platform-profile-follows "${platform[*]}" \
  test "${platform[*]}" = "power-saver=quiet balanced=balanced performance=performance"
check cpu-limits-follow-profile "${cpu[*]}" test "$cpu_ok" = true
check fan-curves-follow-profile "${fan_found[*]:-every fan of quiet, balanced and performance matches}" \
  test "${#fan_found[@]}" -eq 0
check armoury-limits-follow-profile "${armoury_found[*]:-quiet, balanced and performance match on $power_source}" \
  test "${#armoury_found[@]}" -eq 0
# A long-running oruc-* service that crashed, for example on a command its
# path lacks, shows as inactive or restarted; its restart count clears when
# the unit restarts. Oneshots and units a timer starts are left out.
running=()
broken=()
while read -r unit state _; do
  [[ $state == enabled ]] || continue
  declare -A unit_state=()
  while IFS== read -r key value; do
    unit_state[$key]=$value
  done < <(systemctl show -p Type -p TriggeredBy -p ActiveState -p NRestarts "$unit")
  [[ ${unit_state[Type]} == oneshot || -n ${unit_state[TriggeredBy]} ]] && continue
  running+=("$unit=${unit_state[ActiveState]}/${unit_state[NRestarts]} restarts")
  [[ ${unit_state[ActiveState]} == active && ${unit_state[NRestarts]} == 0 ]] ||
    broken+=("$unit")
done < <(systemctl list-unit-files --no-legend 'oruc-*.service')
check oruc-long-running-units "${running[*]:-none found}" \
  test "${#running[@]}" -gt 0 -a "${#broken[@]}" -eq 0
check asusd-profile-switching-off "asusd.ron" \
  grep -q 'change_platform_profile_on_ac: false' /etc/asusd/asusd.ron
check slash-off-on-battery "asusctl slash get" \
  bash -c 'asusctl slash get | grep -qx "Show on battery: false"'
# Dynamic Boost: nvidia-powerd runs on AC only.
powerd=$(systemctl is-active nvidia-powerd)
expected_powerd=inactive
[[ $online == 1 ]] && expected_powerd=active
check nvidia-powerd-on-ac "$powerd (AC=$online)" test "$powerd" = "$expected_powerd"

check captive-dns-off "$(captive-dns status)" test "$(captive-dns status)" = off
check nextdns-secret "/run/secrets/nextdns-profile" sudo test -s /run/secrets/nextdns-profile
check resolved-dot-nextdns "global DNS uses DoT to NextDNS" \
  bash -c 'resolvectl status | sed -n "/^Global/,/^Link/p" | grep -q "+DNSOverTLS" && resolvectl dns | grep -q "^Global:.*dns\.nextdns\.io"'
check public-name-resolves "resolvectl query nixos.org" resolvectl query nixos.org
risoluto_answer=$(resolvectl query --cache=no --legend=no openchamber.risoluto.dev 2>/dev/null | awk 'NR == 1 { print $2 }')
check risoluto-dev-allowlisted "openchamber.risoluto.dev -> ${risoluto_answer:-no answer}" \
  bash -c '[[ $1 == 100.* ]]' _ "$risoluto_answer"
tailnet_name=$(tailscale status --json --peers=false 2>/dev/null |
  sed -n 's/^ *"DNSName": "\(.*\)\.",$/\1/p')
check tailscale-running "${tailnet_name:-not logged in}" test -n "$tailnet_name"
check magicdns-resolves "$tailnet_name" resolvectl query "$tailnet_name"

check easyeffects-installed "$(command -v easyeffects || echo absent)" command -v easyeffects
easyeffects_unit=$(systemctl --user is-enabled easyeffects.service 2>&1)
check easyeffects-user-unit "easyeffects.service is ${easyeffects_unit}" test "$easyeffects_unit" = enabled
units=$HOME/.config/systemd/user
for unit in noctalia dms gnome-keyring blueman-applet; do
  # The install links exist whichever session is running. A link from a
  # target every session reaches would start the unit under Plasma too.
  check "session-scope-$unit" "wanted by niri.service only" \
    bash -c "test -L '$units/niri.service.wants/$unit.service' &&
      test ! -e '$units/graphical-session.target.wants/$unit.service' &&
      test ! -e '$units/graphical-session-pre.target.wants/$unit.service'"
done
# Both niri sessions start niri.service, so each shell also checks the
# variable that its session's launcher sets.
for shell in noctalia dms; do
  check "shell-scope-$shell" "ConditionEnvironment=ORUC_SHELL=$shell" \
    grep -qx "ConditionEnvironment=ORUC_SHELL=$shell" "$units/$shell.service"
done

# The panel widgets and KWin effects that the deployed config turns on. A
# widget is QML under share/plasma/plasmoids or a compiled applet plugin.
if [[ -n ${plasma_widgets:-} ]]; then
  missing=()
  IFS=, read -ra widgets <<<"$plasma_widgets"
  for widget in "${widgets[@]}"; do
    found=false
    for root in "/etc/profiles/per-user/$USER" /run/current-system/sw; do
      if [[ -e $root/share/plasma/plasmoids/$widget || -e $root/lib/qt-6/plugins/plasma/applets/$widget.so ]]; then
        found=true
        break
      fi
    done
    $found || missing+=("$widget")
  done
  check plasma-widgets-installed "missing: ${missing[*]:-none}" test "${#missing[@]}" -eq 0
fi
# A running session keeps the plugins it loaded at login, so a deploy that
# drops or adds one shows only after the next login.
if [[ -n ${plasma_widgets:-}${kwin_effects:-} ]]; then
  plasma_pid=$(systemctl --user show -p MainPID --value plasma-plasmashell 2>/dev/null)
  if [[ ${plasma_pid:-0} == 0 ]]; then
    report plasma-session manual "No Plasma session runs; log in to Plasma and rerun"
  elif (($(date +%s) - $(ps -o etimes= -p "$plasma_pid") < $(stat -c %Y /run/current-system))); then
    report plasma-session manual \
      "plasmashell started before the current system; log out and in to load it, then rerun"
  else
    report plasma-session pass "plasmashell started after the current system"
    if [[ -n ${kwin_effects:-} ]]; then
      loaded=$(busctl --user get-property org.kde.KWin /Effects org.kde.kwin.Effects loadedEffects 2>/dev/null)
      missing=()
      IFS=, read -ra effects <<<"$kwin_effects"
      for effect in "${effects[@]}"; do
        [[ $loaded == *\"$effect\"* ]] || missing+=("$effect")
      done
      check kwin-effects-loaded "not loaded: ${missing[*]:-none}" test "${#missing[@]}" -eq 0
    fi
  fi
fi

# Last, so the checks above give the idle dGPU time to power off.
if [[ -n $nvidia_dev ]]; then
  for _ in {1..30}; do
    status=$(<"/sys/bus/pci/devices/$nvidia_dev/power/runtime_status")
    [[ $status == suspended ]] && break
    sleep 1
  done
  check dgpu-runtime-suspended "$status" test "$status" = suspended
fi
REMOTE
}

status=0
remote_checks >>"$results" || status=$?
case $status in
  0) ;;
  66) record verify-facts fail "/etc/oruc/verify-facts is missing on $host or lacks a fact the checks need; deploy a system that writes it" ;;
  *) record remote-checks fail "SSH to $host failed (exit $status)" ;;
esac

# The panel file holds the settings of the last panel build, so it is compared
# only after a build from this system's panel script, at a login or by
# scripts/panels-rebuild-on-rog.sh.
build=$(
  ssh "${ssh_opts[@]}" "$host" 'bash -s' <<'REMOTE' || true
manager=$HOME/.local/share/plasma-manager
if [[ ! -r /etc/oruc/verify-plasma-panels.json ]]; then
  echo none
elif [[ $(sha256sum "$manager/data/desktop_script_panels.js" 2>/dev/null) == "$(cat "$manager/last_run_desktop_script_panels" 2>/dev/null)" ]]; then
  echo current
else
  echo old
fi
REMOTE
)
case $build in
  none) record plasma-panel-settings manual "$host has no /etc/oruc/verify-plasma-panels.json; deploy a system that writes it, then rerun" ;;
  old) record plasma-panel-settings manual "the panels were not built from this system's panel script; log out and in, or run scripts/panels-rebuild-on-rog.sh, then rerun" ;;
  current)
    compared=0
    if ssh "${ssh_opts[@]}" "$host" cat /etc/oruc/verify-plasma-panels.json >"$work/expected.json" &&
      ssh "${ssh_opts[@]}" "$host" cat .config/plasma-org.kde.plasma.desktop-appletsrc >"$work/appletsrc"; then
      differences=$(python3 -I "$repo_dir/scripts/lib/plasma-panel-settings.py" "$work/expected.json" "$work/appletsrc" 2>&1) || compared=$?
    else
      compared=255
    fi
    case $compared in
      0) record plasma-panel-settings pass "the panel file holds every setting in plasma-panels.nix" ;;
      # A difference is usually a change made in Plasma's settings, which the
      # next panel build drops, so the detail asks before a rebuild.
      1) record plasma-panel-settings fail "${differences//$'\n'/; }. A change made in Plasma lasts only until the next panel build; ask Omer whether to write it into plasma-panels.nix before you rebuild the panels" ;;
      *) record plasma-panel-settings fail "could not compare the panel file (exit $compared): ${differences:-copy from $host failed}" ;;
    esac
    ;;
  *) record plasma-panel-settings fail "could not read the panel build state on $host" ;;
esac

if [[ -n $lan_ip ]]; then
  # Only a refusal or a timeout shows that nothing answers; any other error
  # says nothing about the port.
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

# A suspend darkens the screen of whoever uses the laptop. In use means the
# seat's active session is a local user session that is neither idle nor
# locked. The host exits 0 only when it read the session and it is not in
# use, so a failed read also stops the cycles.
if [[ $suspend == true && $while_in_use == false ]]; then
  if ! ssh "${ssh_opts[@]}" "$host" 'bash -s' <<'REMOTE'
set -euo pipefail
id=$(loginctl show-seat seat0 -p ActiveSession --value)
[[ -n $id ]] || exit 0
# loginctl prints the properties in its own order, so sort them.
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
  # The kernel counts a suspend as successful only when the system really
  # slept and woke; the journal's "PM: suspend exit" also appears for a failed
  # one. The loop stops at the first failed rtcwake.
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
  # Three cycles take 120 s; poll until the success counter has grown by 3.
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
