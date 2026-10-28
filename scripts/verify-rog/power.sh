# shellcheck shell=bash
# shellcheck disable=SC1097,SC2034,SC2086,SC2154,SC2155
check hostname "$(hostname)" test "$(hostname)" = nixos-rog
check sudo-without-password "sudo -n true" sudo -n true
check wifi-interface "$wifi is up" test "$(cat "/sys/class/net/$wifi/operstate" 2>/dev/null)" = up

limine_conf=$(sudo cat /boot/limine/limine.conf 2>/dev/null)
entries=$(grep -E '^ *//?[^ ]' <<<"$limine_conf" | sed 's/^ *//' | tr '\n' ';')
check limine-windows-entry "$entries" grep -q '^/Windows$' <<<"$limine_conf"
check limine-nixos-entries "NixOS generations in limine.conf" grep -q 'Generation' <<<"$limine_conf"
free_mib=$(($(df -B1 --output=avail /boot | tail -n 1) / 1048576))
check esp-free-1gib "${free_mib} MiB free on /boot" test "$free_mib" -ge 1024

scx_ops=$(cat /sys/kernel/sched_ext/root/ops 2>/dev/null)
check sched-ext-lavd "$scx_ops" test "${scx_ops%%_*}" = lavd
dgpu_disable=$(<"$armoury/dgpu_disable/current_value")
gpu_mux=$(<"$armoury/gpu_mux_mode/current_value")
check gpu-mode-hybrid "dgpu_disable=$dgpu_disable gpu_mux_mode=$gpu_mux" test "$dgpu_disable$gpu_mux" = 01
check rtx4070-on-pci "${nvidia_dev:-absent}" test -n "$nvidia_dev"
loaded_version=$(cat /sys/module/nvidia/version 2>/dev/null)
check nvidia-driver "${loaded_version:-not loaded}" test "$loaded_version" = "$nvidia_version"

profile=$(powerprofilesctl get)
ppd_state=$(systemctl is-active power-profiles-daemon)
saved=$(sed -n 's/^Profile=//p' /var/lib/power-profiles-daemon/state.ini 2>/dev/null)
check ppd-profile-kept "power-profiles-daemon is $ppd_state; saved ${saved:-nothing}, running $profile" \
  test "$ppd_state/${saved:-balanced}" = "active/$profile"
online=$(cat /sys/class/power_supply/ACAD/online)
capacity=$(cat /sys/class/power_supply/BAT1/capacity)
if [[ $online == 0 && $capacity -le $low_battery_percent ]]; then
  check ppd-profile "$profile on low battery (battery=$capacity%)" test "$profile" = power-saver
else
  check ppd-profile "$profile as chosen (AC=$online, battery=$capacity%)" test -n "$profile"
fi
if [[ $online == 1 ]]; then
  check low-battery-undone "/run/oruc-low-battery/active absent on AC" test ! -e /run/oruc-low-battery/active
fi
expected_boost=1
[[ $profile == power-saver ]] && expected_boost=0
boost=$(sort -u /sys/devices/system/cpu/cpufreq/policy*/boost | tr '\n' ' ')
boost=${boost% }
check boost-per-profile "boost=$boost in $profile" test "$boost" = "$expected_boost"
curve_dir=
for dir in /sys/class/hwmon/hwmon*; do
  [[ $(<"$dir/name") == asus_custom_fan_curve ]] && curve_dir=$dir
done
power_source=dc
[[ $online == 1 ]] && power_source=ac
fans=([1]=cpu [2]=gpu [3]=mid)
fan_curve_diffs() {
  local n temps_fact pwms_fact temps pwms enable
  [[ -n $curve_dir ]] || {
    echo "no asus_custom_fan_curve hwmon"
    return
  }
  for n in "${!fans[@]}"; do
    temps_fact=fan_temps_${1}_${fans[n]} pwms_fact=fan_pwms_${1}_${fans[n]}
    temps=$(cat "$curve_dir"/pwm${n}_auto_point{1..8}_temp | paste -sd,)
    pwms=$(cat "$curve_dir"/pwm${n}_auto_point{1..8}_pwm | paste -sd,)
    enable=$(<"$curve_dir/pwm${n}_enable")
    [[ $temps == "${!temps_fact}" && $pwms == "${!pwms_fact}" && $enable == 1 ]] ||
      echo "$1 ${fans[n]} temps $temps pwms $pwms enable $enable, want ${!temps_fact} ${!pwms_fact} 1"
  done
}
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
powerd=$(systemctl is-active nvidia-powerd)
expected_powerd=inactive
[[ $online == 1 ]] && expected_powerd=active
check nvidia-powerd-on-ac "$powerd (AC=$online)" test "$powerd" = "$expected_powerd"
