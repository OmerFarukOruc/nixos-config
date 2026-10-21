# Part of the remote script in scripts/verify-nixos-rog.sh.
# shellcheck shell=bash
# shellcheck disable=SC1087,SC2034,SC2086,SC2154,SC2155
# Last, so the checks above give the idle dGPU time to power off.
if [[ -n $nvidia_dev ]]; then
  for _ in {1..30}; do
    status=$(<"/sys/bus/pci/devices/$nvidia_dev/power/runtime_status")
    [[ $status == suspended ]] && break
    sleep 1
  done
  detail=$status
  if [[ $status != suspended ]]; then
    # KWin keeps /dev/nvidia0 open without waking the GPU. Processes of other
    # users, such as root's nvidia-powerd, are not readable here.
    holders=()
    for proc in /proc/[0-9]*; do
      comm=$(cat "$proc/comm" 2>/dev/null) || continue
      [[ $comm == kwin_wayland* ]] && continue
      for fd in "$proc"/fd/*; do
        if [[ $(readlink "$fd" 2>/dev/null) == /dev/nvidia* ]]; then
          parent=$(awk '/^PPid:/ {print $2}' "$proc/status" 2>/dev/null)
          parent=$(cat "/proc/$parent/comm" 2>/dev/null)
          holders+=("$comm[${proc#/proc/}] under ${parent:-?}")
          break
        fi
      done
    done
    detail="$status; /dev/nvidia open by this user's processes: $(
      IFS=,
      echo "${holders[*]:-none}"
    )"
  fi
  check dgpu-runtime-suspended "$detail" test "$status" = suspended
fi
