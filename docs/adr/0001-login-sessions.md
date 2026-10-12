# A machine record lists login sessions

A machine record used to name one desktop and one shell. nixos-rog offers
Plasma, niri with Noctalia and niri with DMS from the same display manager, so
the record now holds a list of sessions, each a desktop with its shell, and the
first one is the default. We kept one record field instead of per-desktop host
overrides because every consumer (login, desktop, theme, launchers, shells)
must agree on which desktops exist.

## Consequences

- Every session reaches `graphical-session.target`, so a user service that
  belongs to one desktop binds to that desktop's own unit instead. Units this
  repository writes for Plasma name `plasma-workspace.target` directly. Units
  that Home Manager modules define for niri register in `oruc.sessionServices`,
  or in `oruc.shellServices` when one shell owns them, which rebinds them to
  `niri.service` on a machine with more than one session.
- A desktop with more than one shell gets one display manager session per
  shell, named `<desktop>-<shell>`, in place of its own. The session's
  launcher sets `ORUC_SHELL`, and each shell's services start only when it
  matches. For niri the launcher also sets `NIRI_CONFIG` to a file that adds
  the shell's binds after `/etc/niri/config.kdl`.
- With Plasma present, Plasma owns `kdeglobals`, the GTK settings and the
  cursor; the niri session inherits them. A niri-only machine keeps the files
  that Home Manager writes.
