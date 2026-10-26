# systemd 262 refuses a Type=notify-reload service whose main process has no
# handler for the reload signal when it sends READY=1. Ghostty 1.3.1 sends
# READY=1 from the config reload that syncs the color scheme at startup, before
# it installs its SIGUSR2 handler, so Ctrl+Alt+T fails until a start wins the
# race. The patch is the upstream fix:
# https://github.com/ghostty-org/ghostty/pull/14399
# Delete this overlay once a Ghostty release contains it; the patch then fails
# to apply.
_final: prev: {
  ghostty = prev.ghostty.overrideAttrs (old: {
    patches = (old.patches or [ ]) ++ [ ./ghostty-systemd-ready.patch ];
  });
}
