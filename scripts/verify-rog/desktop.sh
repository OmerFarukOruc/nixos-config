# shellcheck shell=bash
# shellcheck disable=SC2034,SC2086,SC2154,SC2155
units=$HOME/.config/systemd/user
for unit in noctalia dms gnome-keyring blueman-applet; do
  check "session-scope-$unit" "wanted by niri.service only" \
    bash -c "test -L '$units/niri.service.wants/$unit.service' &&
      test ! -e '$units/graphical-session.target.wants/$unit.service' &&
      test ! -e '$units/graphical-session-pre.target.wants/$unit.service'"
done
for shell in noctalia dms; do
  check "shell-scope-$shell" "ConditionEnvironment=ORUC_SHELL=$shell" \
    grep -qx "ConditionEnvironment=ORUC_SHELL=$shell" "$units/$shell.service"
done

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
icon_roots=("$HOME/.local/share/icons" "/etc/profiles/per-user/$USER/share/icons" /run/current-system/sw/share/icons)
icon_dirs=()
icon_theme_dirs() {
  local -a queue=("$@" breeze hicolor) more
  local -A seen=()
  local theme root index subdir
  while ((${#queue[@]})); do
    theme=${queue[0]}
    queue=("${queue[@]:1}")
    [[ -n $theme && -z ${seen[$theme]:-} ]] || continue
    seen[$theme]=1
    for root in "${icon_roots[@]}"; do
      index=$root/$theme/index.theme
      [[ -r $index ]] || continue
      for subdir in $(sed -n 's/^\(Scaled\)\{0,1\}Directories=//p' "$index" | tr ',' ' '); do
        icon_dirs+=("$root/$theme/$subdir")
      done
      IFS=, read -ra more <<<"$(sed -n 's/^Inherits=//p' "$index" | head -n 1)"
      queue+=("${more[@]}")
    done
  done
}
icon_found() {
  local name=${1#file://} dir ext
  [[ $name == /* ]] && {
    [[ -e $name ]]
    return
  }
  while [[ -n $name ]]; do
    for dir in "${icon_dirs[@]}" /run/current-system/sw/share/pixmaps; do
      for ext in svg svgz png; do
        [[ -e $dir/$name.$ext ]] && return 0
      done
    done
    [[ $name == *-* ]] || return 1
    name=${name%-*}
  done
  return 1
}
missing_widget_icons() {
  local name icon
  while IFS=$'\t' read -r name icon; do
    [[ -n $name ]] || continue
    [[ -z $icon ]] || icon_found "$icon" || printf '%s: %s\n' "$name" "$icon"
  done <<<"$widget_icon_rows"
}
scheme=$(cat "$HOME/.local/state/oruc/scheme" 2>/dev/null || echo "${scheme_default:-}")
panels_file=/etc/oruc/verify-plasma-panels/${plasma_look:-}_$scheme.json
if [[ -r $panels_file ]]; then
  if [[ ${widget_icon_ok:-0} != 1 ]]; then
    report plasma-widget-icons manual "could not copy plasmoid main.xml to resolve icon defaults"
  else
    icon_theme_dirs "$(kreadconfig6 --file kdeglobals --group Icons --key Theme --default breeze)"
    missing_icons=$(missing_widget_icons | paste -sd , -)
    check plasma-widget-icons "not found: ${missing_icons:-none}" test -z "$missing_icons"
  fi
else
  report plasma-widget-icons manual "no $panels_file; deploy a system that writes it, then rerun"
fi
oled_care=/etc/profiles/per-user/$USER/bin/mac-tahoe-oled-care
if [[ ! -x $oled_care ]]; then
  report oled-care-state fail "$oled_care is missing; machines/nixos-rog/oled-care.nix installs it"
elif oled_status=$("$oled_care" status 2>&1); then
  report oled-care-state pass "no failed shift stopped the panel shifts"
else
  report oled-care-state fail "$(head -n 1 <<<"$oled_status"); docs/nixos-rog.md, Plasma panels, says how to recover"
fi
if systemctl --user -q is-active plasma-workspace.target; then
  check oled-care-timer "oled-care.timer runs in the Plasma session" \
    systemctl --user -q is-active oled-care.timer
fi
if [[ -n ${plasma_widgets:-}${kwin_effects:-} ]]; then
  plasma_pid=$(systemctl --user show -p MainPID --value plasma-plasmashell 2>/dev/null)
  changed=$(stat -c %Y /run/current-system)
  look_changed=$(stat -c %Y "$plasma_look_file" 2>/dev/null || echo 0)
  ((look_changed > changed)) && changed=$look_changed
  if [[ ${plasma_pid:-0} == 0 ]]; then
    report plasma-session manual "No Plasma session runs; log in to Plasma and rerun"
  elif (($(date +%s) - $(ps -o etimes= -p "$plasma_pid") < changed)); then
    report plasma-session manual \
      "plasmashell started before the current system or the last plasma-look; log out and in to load it, then rerun"
  else
    report plasma-session pass "plasmashell started after the current system"
    if [[ -n ${kwin_effects:-} ]]; then
      loaded=$(busctl --user get-property org.kde.KWin /Effects org.kde.kwin.Effects loadedEffects 2>/dev/null)
      missing=()
      IFS=, read -ra effects <<<"$kwin_effects"
      for effect in "${effects[@]}"; do
        [[ $loaded == *\"$effect\"* || $loaded == *\"kwin4_effect_$effect\"* ]] || missing+=("$effect")
      done
      check kwin-effects-loaded "not loaded: ${missing[*]:-none}" test "${#missing[@]}" -eq 0
    fi
  fi
fi
