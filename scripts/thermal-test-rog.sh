#!/usr/bin/env bash
# usage: scripts/thermal-test-rog.sh PROFILE [--ppt PL1,PL2,PL3]
#          [--fans 'CPU=T:P,... GPU=T:P,... MID=T:P,...'] [--threads N]
#          [--seconds S] [--label LABEL]
# Loads the CPU of nixos-rog in a power-profiles-daemon PROFILE (power-saver,
# balanced or performance) with stress-ng and records, every 5 s through the
# load and 30 s of cooldown: Tctl, package power, the three fan speeds, the
# mean clock and the SMU temperature limit. It heats the laptop and runs the
# fans hard for several minutes, and needs the charger plugged in.
#
# --ppt (watts) and --fans override the profile's power limits and fan curves
# for this run; each curve is 8 TEMP:PWM points, both rising left to right.
# The overrides follow the profile switch, because every switch, even to the
# current profile, makes asusd rewrite both. --threads 0, the default, loads
# every CPU; --seconds defaults to 240.
#
# On exit, also after Ctrl-C, it sets the original profile again and restarts
# asusd and oruc-cpu-limits, which write that profile's limits and curves.
# The samples go to ~/.local/state/nixos-config-thermal/TIME-LABEL.tsv.
set -euo pipefail

host=nixos-rog
ssh_opts=(-o BatchMode=yes -o ConnectTimeout=15)

die() {
  echo "$0: $*" >&2
  exit 2
}

(($# >= 1)) || die "give a profile: power-saver, balanced or performance"
profile=$1
shift
case $profile in
  power-saver | balanced | performance) ;;
  *) die "unknown profile $profile" ;;
esac
ppt=-
fans=
threads=0
seconds=240
label=$profile
while (($# > 0)); do
  (($# >= 2)) || die "$1 needs a value"
  case $1 in
    --ppt) ppt=$2 ;;
    --fans) fans=$2 ;;
    --threads) threads=$2 ;;
    --seconds) seconds=$2 ;;
    --label) label=$2 ;;
    *) die "unknown option $1" ;;
  esac
  shift 2
done
[[ $ppt == - || $ppt =~ ^[0-9]+,[0-9]+,[0-9]+$ ]] || die "--ppt takes PL1,PL2,PL3 in watts"
[[ $threads =~ ^[0-9]+$ ]] || die "--threads takes a number"
if [[ ! $seconds =~ ^[0-9]+$ ]] || ((10#$seconds < 10 || 10#$seconds > 1800)); then
  die "--seconds takes 10 to 1800"
fi
seconds=$((10#$seconds))
[[ $label =~ ^[A-Za-z0-9._-]+$ ]] || die "--label takes letters, digits, dot, dash and underscore"

# The host takes each curve as N=POINTS, where N is the hwmon pwmN of the fan.
curves=()
read -ra groups <<<"$fans"
for group in "${groups[@]}"; do
  name=${group%%=*}
  case $name in
    CPU) n=1 ;;
    GPU) n=2 ;;
    MID) n=3 ;;
    *) die "fan $name: use CPU, GPU or MID" ;;
  esac
  IFS=, read -ra points <<<"${group#*=}"
  ((${#points[@]} == 8)) || die "fan $name: give 8 TEMP:PWM points"
  last_temp=0
  last_pwm=0
  for point in "${points[@]}"; do
    [[ $point =~ ^([0-9]+):([0-9]+)$ ]] || die "fan $name: $point is not TEMP:PWM"
    temp=$((10#${BASH_REMATCH[1]}))
    pwm=$((10#${BASH_REMATCH[2]}))
    ((temp <= 100 && pwm <= 255 && temp >= last_temp && pwm >= last_pwm)) ||
      die "fan $name: temperatures 0-100 and PWM 0-255, each rising left to right"
    last_temp=$temp
    last_pwm=$pwm
  done
  curves+=("$n=${group#*=}")
done

[[ $(ssh "${ssh_opts[@]}" "$host" cat /sys/class/power_supply/ACAD/online) == 1 ]] ||
  die "nixos-rog runs on battery; plug in the charger"
original=$(ssh "${ssh_opts[@]}" "$host" powerprofilesctl get)

state=$HOME/.local/state/nixos-config-thermal
mkdir -p "$state"
out=$state/$(date -u +%Y%m%dT%H%M%SZ)-$label.tsv

# The remote commands below are built here on purpose, each value through
# printf %q, because the host's login shell is zsh.
restore() {
  # shellcheck disable=SC2029
  ssh "${ssh_opts[@]}" "$host" \
    "sudo -n powerprofilesctl set $(printf %q "$original") && sudo -n systemctl restart asusd oruc-cpu-limits" ||
    echo "restore failed: set $original and restart asusd and oruc-cpu-limits on $host" >&2
}
trap restore EXIT
trap 'exit 130' INT TERM HUP

status=0
# shellcheck disable=SC2029
ssh "${ssh_opts[@]}" "$host" \
  "bash -s -- $(printf '%q ' "$profile" "$ppt" "$threads" "$seconds" "${curves[@]}")" <<'REMOTE' |
set -euo pipefail
profile=$1 ppt=$2 threads=$3 seconds=$4
shift 4

exec 9>/tmp/thermal-test-rog.lock
if ! flock -n 9; then
  echo "another thermal test runs on this host" >&2
  exit 75
fi
release=$(readlink -f ~/.local/state/nixos-config-deploy/current)
stress=$(cd "$release" && nix build --no-link --print-out-paths --no-write-lock-file \
  .#nixosConfigurations.nixos-rog.pkgs.stress-ng </dev/null)/bin/stress-ng
# hwmon numbers change between boots, so each is found by its name.
hwmon() {
  local dir
  for dir in /sys/class/hwmon/hwmon*; do
    if [[ $(<"$dir/name") == "$1" ]]; then
      echo "$dir"
      return
    fi
  done
  echo "no hwmon named $1" >&2
  return 1
}
k10temp=$(hwmon k10temp)
amdgpu=$(hwmon amdgpu)
asus=$(hwmon asus)
curve=$(hwmon asus_custom_fan_curve)
write() { echo "$1" | sudo -n tee "$2" >/dev/null; }

sudo -n powerprofilesctl set "$profile"
# asusd finished its rewrite 75 ms after a profile set in its journal, so the
# overrides below come last.
sleep 4
if [[ $ppt != - ]]; then
  armoury=/sys/class/firmware-attributes/asus-armoury/attributes
  IFS=, read -r pl1 pl2 pl3 <<<"$ppt"
  write "$pl1" "$armoury/ppt_pl1_spl/current_value"
  write "$pl2" "$armoury/ppt_pl2_sppt/current_value"
  write "$pl3" "$armoury/ppt_pl3_fppt/current_value"
fi
for spec in "$@"; do
  n=${spec%%=*}
  IFS=, read -ra points <<<"${spec#*=}"
  for i in "${!points[@]}"; do
    write "${points[i]%%:*}" "$curve/pwm${n}_auto_point$((i + 1))_temp"
    write "${points[i]##*:}" "$curve/pwm${n}_auto_point$((i + 1))_pwm"
  done
  # The MID fan's enable file answers ENODEV, but its new curve still applies.
  write 1 "$curve/pwm${n}_enable" 2>/dev/null || ((n == 3))
done

printf '# profile=%s ppt=%s threads=%s seconds=%s fans=%s release=%s\n' \
  "$profile" "$ppt" "$threads" "$seconds" "${*:--}" "${release##*/}"
printf 't_s\tphase\ttctl_c\tppt_w\tcpu_rpm\tgpu_rpm\tmid_rpm\tmhz\tsmu_limit_c\n'
"$stress" --cpu "$threads" --cpu-method matrixprod --timeout "${seconds}s" >/dev/null 2>&1 &
load=$!
# A Ctrl-C on fedora closes this script's output. The next sample write then
# ends the script, and the EXIT trap stops the load with it.
trap 'kill "$load" 2>/dev/null' EXIT
trap 'exit 141' PIPE
start=$SECONDS
for ((t = 0; t <= seconds + 30; t = SECONDS - start)); do
  phase=load
  ((t < seconds)) || phase=cool
  mhz=$(awk '{ s += $1 } END { printf "%d", s / NR / 1000 }' \
    /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq)
  limit=$(sudo -n ryzenadj -i 2>/dev/null | awk -F'|' '/THM LIMIT CORE/ { printf "%d", $3 }')
  printf '%d\t%s\t%d\t%d\t%d\t%d\t%d\t%d\t%s\n' "$t" "$phase" \
    $(($(<"$k10temp/temp1_input") / 1000)) $(($(<"$amdgpu/power1_input") / 1000000)) \
    "$(<"$asus/fan1_input")" "$(<"$asus/fan2_input")" "$(<"$asus/fan3_input")" "$mhz" "$limit"
  sleep 5
done
wait "$load"
REMOTE
  tee "$out" || status=$?
if ((status == 75)); then
  trap - EXIT
  rm -f -- "$out"
  exit 75
fi
((status == 0)) || exit "$status"

awk -F'\t' -v seconds="$seconds" '
  $1 ~ /^[0-9]+$/ {
    if ($3 > peak) peak = $3
    if ($5 > cpu) cpu = $5
    if ($7 > mid) mid = $7
    if ($2 == "load" && $1 >= seconds - 40) { mhz += $8; n++ }
  }
  END {
    printf "peak %d °C, %d MHz over the last 40 s of load, fans up to CPU %d and MID %d rpm\n",
      peak, (n ? mhz / n : 0), cpu, mid
  }' "$out"
echo "samples: $out"
