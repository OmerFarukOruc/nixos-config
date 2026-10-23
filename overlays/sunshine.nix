# Sunshine restarts itself, from its tray menu or web UI, by exec'ing
# /proc/self/exe. That is the unwrapped binary, not the capability wrapper
# that services.sunshine.capSysAdmin starts, so the restarted Sunshine lacks
# CAP_SYS_ADMIN, cannot capture the screen with KMS and streams nothing. This
# makes a restart exit with status 75 instead; nixosModules/remote-desktop.nix
# has systemd start it again through the wrapper. The build fails when either
# replaced line is missing from the source.
_final: prev: {
  sunshine = prev.sunshine.overrideAttrs (old: {
    postPatch = (old.postPatch or "") + ''
      substituteInPlace src/platform/linux/misc.cpp \
        --replace-fail 'atexit(restart_on_exit);' "" \
        --replace-fail 'lifetime::exit_sunshine(0, true);' 'lifetime::exit_sunshine(75, true);'
    '';
  });
}
