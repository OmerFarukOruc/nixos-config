# Part of the remote script in scripts/verify-nixos-rog.sh.
# shellcheck shell=bash
# shellcheck disable=SC2034,SC2086,SC2154,SC2155
check easyeffects-installed "$(command -v easyeffects || echo absent)" command -v easyeffects
easyeffects_unit=$(systemctl --user is-enabled easyeffects.service 2>&1)
check easyeffects-user-unit "easyeffects.service is ${easyeffects_unit}" test "$easyeffects_unit" = enabled
export XDG_RUNTIME_DIR=/run/user/$(id -u)
default_source=$(wpctl inspect @DEFAULT_AUDIO_SOURCE@ 2>/dev/null | sed -n 's/^ *\* node.name = "\(.*\)"$/\1/p')
check default-source-hushmic "${default_source:-none}" test "$default_source" = hushmic_source
ee_rc=$HOME/.config/easyeffects/db/easyeffectsrc
ee_pinned=$(grep -hE '^(useDefaultInputDevice|inputDevice|bypass)=' "$ee_rc" 2>/dev/null | sort | paste -sd' ')
check easyeffects-input-pinned "$ee_pinned" test "$ee_pinned" = "bypass=false inputDevice=alsa_input.pci-0000_66_00.6.analog-stereo useDefaultInputDevice=false"
# .inference stays null until an app records from HushMic, so this reads the
# configured model.
hushmic_model=$(hushmic status --json 2>/dev/null | jq -r 'select(.enabled and .chain.running and .chain.node_present and .mode == "suppress" and .mic.active == "alsa_input.pci-0000_66_00.6.analog-stereo") | .model')
check hushmic-active "${hushmic_model:-not running}" test "$hushmic_model" = dpdfnet8_48khz_hr
