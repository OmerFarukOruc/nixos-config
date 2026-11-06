# power-profiles-daemon 0.30 returns to its selected profile when the last
# profile hold ends, such as `powerprofilesctl launch` in game-nvidia, but sets
# that profile only on a user's switch. It starts in the profile saved in
# state.ini and saves a profile the driver switched to by itself, yet keeps the
# selected profile at balanced or the previous choice, so the hold ends in that
# profile instead of the saved one
# (https://gitlab.freedesktop.org/upower/power-profiles-daemon/-/blob/0.30/src/power-profiles-daemon.c#L507,
# #L605 and #L784).
_final: prev: {
  power-profiles-daemon = prev.power-profiles-daemon.overrideAttrs (old: {
    postPatch = (old.postPatch or "") + ''
      substituteInPlace src/power-profiles-daemon.c \
        --replace-fail \
          "data->active_profile = profile;" \
          "data->active_profile = data->selected_profile = profile;" \
        --replace-fail \
          "    save_configuration (data);" \
          "    { data->selected_profile = target_profile; save_configuration (data); }"
    '';
  });
}
