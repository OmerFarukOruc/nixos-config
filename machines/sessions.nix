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

  hasGraphicalUser = machine: hasAnyDesktop machine || machine.features.streamedDesktop;
  desktops = machine: lib.unique (map (session: session.desktop) machine.sessions);

  hasDesktop = machine: desktop: builtins.elem (knownDesktop desktop) (desktops machine);

  hasShell = machine: shell: lib.any (session: session.shell == knownShell shell) machine.sessions;

  shellsOf =
    machine: desktop:
    map (session: session.shell) (lib.filter (session: session.desktop == desktop) machine.sessions);

  desktopOf =
    machine: shell:
    (lib.findFirst (
      session: session.shell == shell
    ) (throw "${machine.name} has no session that runs the shell ${shell}") machine.sessions).desktop;

  hasSeveralShells = machine: desktop: lib.length (shellsOf machine desktop) > 1;

  sessionName =
    machine: session:
    if hasSeveralShells machine session.desktop then
      "${session.desktop}-${session.shell}"
    else
      session.desktop;

  defaultSession =
    machine:
    if machine.sessions == [ ] then
      throw "${machine.name} has no session, so it has no default session"
    else
      sessionName machine (builtins.head machine.sessions);

  isMultiSession = machine: lib.length machine.sessions > 1;
}
