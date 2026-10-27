# Questions about a machine's login sessions, asked by the modules that adapt
# to them. A machine record lists its sessions in oruc.machine.sessions.
{ lib }:
let
  selectors = import ./selectors.nix;
in
rec {
  knownDesktop =
    desktop:
    if builtins.elem desktop selectors.desktopNames then
      desktop
    else
      throw "Unknown desktop ${desktop}. Known desktops: ${lib.concatStringsSep ", " selectors.desktopNames}";
  knownShell =
    shell:
    if builtins.elem shell selectors.shellNames then
      shell
    else
      throw "Unknown shell ${shell}. Known shells: ${lib.concatStringsSep ", " selectors.shellNames}";

  hasAnyDesktop = machine: machine.sessions != [ ];

  # Whether oruc works in a graphical session that the machine has no login
  # session for: the streamed desktop of a server. The modules that give a
  # graphical user fonts, a browser and a keyboard layout ask this; the login
  # screen, Ghostty and the shells ask hasAnyDesktop.
  hasGraphicalUser = machine: hasAnyDesktop machine || machine.features.streamedDesktop;
  desktops = machine: lib.unique (map (session: session.desktop) machine.sessions);

  hasDesktop = machine: desktop: builtins.elem (knownDesktop desktop) (desktops machine);

  hasShell = machine: shell: lib.any (session: session.shell == knownShell shell) machine.sessions;

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

  # Name of the default session, the first one listed.
  defaultSession =
    machine:
    if machine.sessions == [ ] then
      throw "${machine.name} has no session, so it has no default session"
    else
      sessionName machine (builtins.head machine.sessions);

  # With more than one session, a user service that belongs to one session
  # must not start in the others.
  isMultiSession = machine: lib.length machine.sessions > 1;
}
