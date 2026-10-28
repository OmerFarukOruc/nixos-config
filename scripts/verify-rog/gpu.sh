# shellcheck shell=bash
# shellcheck disable=SC1087,SC2034,SC2086,SC2154,SC2155
if [[ -n $nvidia_dev ]]; then
  outputs=()
  for connector in "/sys/bus/pci/devices/$nvidia_dev"/drm/card*/card*-*; do
    [[ $(cat "$connector/status" 2>/dev/null) == connected &&
    $(cat "$connector/enabled" 2>/dev/null) == enabled ]] || continue
    name=${connector##*/}
    outputs+=("${name#card*-}")
  done
  for _ in {1..30}; do
    status=$(<"/sys/bus/pci/devices/$nvidia_dev/power/runtime_status")
    [[ $status == suspended || ${#outputs[@]} -gt 0 ]] && break
    sleep 1
  done
  detail=$status
  want=suspended
  if ((${#outputs[@]})); then
    want=active
    detail="$status; drives $(
      IFS=,
      echo "${outputs[*]}"
    )"
  elif [[ $status != suspended ]]; then
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
  check dgpu-runtime-suspended "$detail" test "$status" = "$want"
fi
