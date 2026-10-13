# Questions about a machine's login sessions, asked by the modules that adapt
# to them. A machine record lists its sessions in oruc.machine.sessions.
{ lib }:
rec {
  hasAnyDesktop = machine: machine.sessions != [ ];
  desktops = machine: lib.unique (map (session: session.desktop) machine.sessions);

  hasDesktop = machine: desktop: builtins.elem desktop (desktops machine);

  hasShell = machine: shell: lib.any (session: session.shell == shell) machine.sessions;

  # Shells of this desktop's sessions, in session order.
  shellsOf =
    machine: desktop:
    map (session: session.shell) (lib.filter (session: session.desktop == desktop) machine.sessions);

  # Desktop of the session that runs this shell.
  desktopOf =
    machine: shell:
    (lib.findFirst (
      session: session.shell == shell
    ) (throw "${machine.name} has no session that runs the shell ${shell}") machine.sessions).desktop;

  # A desktop with more than one shell offers one display manager session per shell.
  hasSeveralShells = machine: desktop: lib.length (shellsOf machine desktop) > 1;

  # Name of the display manager session, the basename of its .desktop file.
  sessionName =
    machine: session:
    if hasSeveralShells machine session.desktop then
      "${session.desktop}-${session.shell}"
    else
      session.desktop;

  # Name of the default session, the first one listed. A machine with no session
  # has none, so callers check hasAnyDesktop first.
  defaultSession = machine: sessionName machine (builtins.head machine.sessions);

  # With more than one session, a user service that belongs to one session
  # must not start in the others.
  isMultiSession = machine: lib.length machine.sessions > 1;
}
