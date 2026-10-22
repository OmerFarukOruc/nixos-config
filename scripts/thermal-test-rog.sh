#!/usr/bin/env bash
# usage: scripts/thermal-test-rog.sh PROFILE [--ppt PL1,PL2,PL3]
#          [--fans 'CPU=TEMP:PWM,... GPU=TEMP:PWM,... MID=TEMP:PWM,...'] [--threads N]
#          [--load cpu|gpu|both] [--seconds S] [--label LABEL]
# Loads nixos-rog in a power-profiles-daemon PROFILE (power-saver, balanced or
# performance) and records, every 5 s through the load and 30 s of cooldown:
# Tctl, package power, the three fan speeds, the mean clock and the SMU
# temperature limit. It heats the laptop and runs the fans hard for several
# minutes, and needs the charger plugged in.
#
# --load picks what runs: stress-ng on the CPU (cpu, the default), gpu-burn on
# the RTX 4070 (gpu) or both. With a GPU load it also records the RTX 4070's
# power draw, temperature and clock from nvidia-smi; without one it leaves
# those columns at -, because nvidia-smi keeps the GPU awake.
#
# --ppt (watts) and --fans override the profile's power limits and fan curves
# for this run. Each --fans group names one fan (CPU, GPU or MID) and gives 8
# TEMP:PWM points, TEMP in degrees C (0-100) and PWM raw (0-255), never
# falling left to right; fans you leave out keep the profile's curve, as in
# --fans 'CPU=40:0,45:40,50:60,55:80,60:100,65:140,70:180,75:255'.
# The overrides follow the profile switch, because every switch, even to the
# current profile, makes asusd rewrite both. --threads (default 0, every CPU)
# sets the CPU load's threads; --seconds takes 10 to 1800 (default 240);
# --label names the file and defaults to PROFILE.
#
# Exit status: 2 for a usage error or battery power, 3 when the platform
# profile changes or the charger is unplugged mid-run, 75 when another run
# holds the lock.
#
# On exit, also after Ctrl-C, it sets the original profile again and restarts
# asusd and oruc-cpu-limits, which write that profile's limits and curves.
# The samples go to ~/.local/state/nixos-config-thermal/TIME-LABEL.tsv. Their
# first line names this script's git blob as script=, so a run cited as
# evidence can be matched to a commit: git rev-parse REV:scripts/thermal-test-rog.sh.
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
load=cpu
seconds=240
label=$profile
while (($# > 0)); do
  (($# >= 2)) || die "$1 needs a value"
  case $1 in
    --ppt) ppt=$2 ;;
    --fans) fans=$2 ;;
    --threads) threads=$2 ;;
    --load) load=$2 ;;
    --seconds) seconds=$2 ;;
    --label) label=$2 ;;
    *) die "unknown option $1" ;;
  esac
  shift 2
done
[[ $ppt == - || $ppt =~ ^[0-9]+,[0-9]+,[0-9]+$ ]] || die "--ppt takes PL1,PL2,PL3 in watts"
[[ $threads =~ ^[0-9]+$ ]] || die "--threads takes a number"
[[ $load =~ ^(cpu|gpu|both)$ ]] || die "--load takes cpu, gpu or both"
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
      die "fan $name: temperatures 0-100 and PWM 0-255, never falling left to right"
    last_temp=$temp
    last_pwm=$pwm
  done
  curves+=("$n=${group#*=}")
done

[[ $(ssh "${ssh_opts[@]}" "$host" cat /sys/class/power_supply/ACAD/online) == 1 ]] ||
  die "nixos-rog runs on battery; plug in the charger"
original=$(ssh "${ssh_opts[@]}" "$host" powerprofilesctl get)
script_blob=$(git hash-object "$0")

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
  "bash -s -- $(printf '%q ' "$profile" "$ppt" "$threads" "$seconds" "$load" "$script_blob" "${curves[@]}")" <<'REMOTE' |
set -euo pipefail
profile=$1 ppt=$2 threads=$3 seconds=$4 load=$5 script_blob=$6
shift 6
cpu_load=false gpu_load=false
[[ $load == gpu ]] || cpu_load=true
[[ $load == cpu ]] || gpu_load=true

exec 9>/tmp/thermal-test-rog.lock
if ! flock -n 9; then
  echo "another thermal test runs on this host" >&2
  exit 75
fi
release=$(readlink -f ~/.local/state/nixos-config-deploy/current)
# heavy (machines/nixos-rog/heavy.nix) caps the evaluation's memory.
build() {
  (cd "$release" && heavy nix build --no-link --print-out-paths --no-write-lock-file \
    ".#nixosConfigurations.nixos-rog.pkgs.$1" </dev/null)
}
! $cpu_load || stress=$(build stress-ng)/bin/stress-ng
# gpu-burn builds only for a CUDA architecture; sm_89 is the RTX 4070's, as
# for whisper-cpp in machines/nixos-rog/media.nix.
! $gpu_load || gpu_burn=$(build pkgsForCudaArch.sm_89.gpu-burn)/bin/gpu_burn
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
platform=$(</sys/firmware/acpi/platform_profile)
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

printf '# profile=%s ppt=%s threads=%s load=%s seconds=%s fans=%s release=%s script=%s\n' \
  "$profile" "$ppt" "$threads" "$load" "$seconds" "${*:--}" "${release##*/}" "$script_blob"
printf 't_s\tphase\ttctl_c\tppt_w\tcpu_rpm\tgpu_rpm\tmid_rpm\tmhz\tsmu_limit_c\tgpu_w\tgpu_c\tgpu_mhz\n'
loads=()
if $cpu_load; then
  "$stress" --cpu "$threads" --cpu-method matrixprod --timeout "${seconds}s" >/dev/null 2>&1 &
  loads+=($!)
fi
if $gpu_load; then
  # gpu_burn forks a worker per GPU, so it runs in its own process group,
  # which the trap below stops whole.
  setsid "$gpu_burn" "$seconds" >/dev/null 2>&1 &
  loads+=(-$!)
fi
# A Ctrl-C in the SSH session that started it closes this script's output.
# The next sample write then ends the script, and the EXIT trap stops the loads and waits for them, so the
# lock stays held until they end. After a complete run the loads have already
# ended, and a failed kill or wait would set the exit status.
trap 'kill -- "${loads[@]}" 2>/dev/null || true; wait || true' EXIT
trap 'exit 141' PIPE
start=$SECONDS
for ((t = 0; t <= seconds + 30; t = SECONDS - start)); do
  # Another program can switch the profile mid-run, and asusd rewrites the
  # limits and curves when the charger goes, so the samples after either
  # would measure something else.
  if [[ $(</sys/firmware/acpi/platform_profile) != "$platform" ]]; then
    echo "the platform profile left $platform at $t s; the test stopped" >&2
    exit 3
  fi
  if [[ $(</sys/class/power_supply/ACAD/online) != 1 ]]; then
    echo "the charger was unplugged at $t s; the test stopped" >&2
    exit 3
  fi
  # gpu_burn starts its clock after it sets up, so the GPU load runs a few
  # seconds into the cooldown.
  phase=load
  ((t < seconds)) || phase=cool
  mhz=$(awk '{ s += $1 } END { printf "%d", s / NR / 1000 }' \
    /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq)
  limit=$(sudo -n ryzenadj -i 2>/dev/null | awk -F'|' '/THM LIMIT CORE/ { printf "%d", $3 }')
  gpu=(- - -)
  if $gpu_load; then
    IFS=', ' read -ra gpu < <(nvidia-smi --query-gpu=power.draw,temperature.gpu,clocks.sm \
      --format=csv,noheader,nounits) || gpu=('?' '?' '?')
  fi
  printf '%d\t%s\t%d\t%d\t%d\t%d\t%d\t%d\t%s\t%s\t%s\t%s\n' "$t" "$phase" \
    $(($(<"$k10temp/temp1_input") / 1000)) $(($(<"$amdgpu/power1_input") / 1000000)) \
    "$(<"$asus/fan1_input")" "$(<"$asus/fan2_input")" "$(<"$asus/fan3_input")" "$mhz" "$limit" \
    "${gpu[0]}" "${gpu[1]}" "${gpu[2]}"
  sleep 5
done
for pid in "${loads[@]}"; do
  wait "${pid#-}"
done
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
    if ($10 != "-" && $10 + 0 > gpu_w) gpu_w = $10 + 0
    if ($11 != "-" && $11 + 0 > gpu_c) gpu_c = $11 + 0
  }
  END {
    printf "peak %d °C, %d MHz over the last 40 s of load, fans up to CPU %d and MID %d rpm",
      peak, (n ? mhz / n : 0), cpu, mid
    if (gpu_w) printf ", RTX 4070 up to %.0f W and %d °C", gpu_w, gpu_c
    printf "\n"
  }' "$out"
echo "samples: $out"
