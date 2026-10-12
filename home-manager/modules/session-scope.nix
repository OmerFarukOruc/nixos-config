{
  config,
  lib,
  osConfig,
  sessions,
  ...
}:
let
  machine = osConfig.oruc.machine;
  selectors = import ../../machines/selectors.nix;

  # The unit that is up exactly while a session of this desktop runs.
  sessionUnit = {
    niri = "niri.service";
    plasma = "plasma-workspace.target";
  };

  bindTo = desktop: unit: {
    Unit = {
      PartOf = lib.mkForce [ sessionUnit.${desktop} ];
      After = [ sessionUnit.${desktop} ];
    }
    // unit;
    Install.WantedBy = lib.mkForce [ sessionUnit.${desktop} ];
  };
in
{
  options.oruc.sessionServices = lib.mkOption {
    type = lib.types.attrsOf (lib.types.enum (builtins.attrNames sessionUnit));
    default = { };
    example = {
      blueman-applet = "niri";
    };
    description = ''
      User services that belong to one desktop, by service name. On a machine
      with more than one session, each one starts and stops with that
      desktop's session instead of graphical-session.target, which every
      session reaches.
    '';
  };

  options.oruc.shellServices = lib.mkOption {
    type = lib.types.attrsOf (lib.types.enum selectors.shellNames);
    default = { };
    example = {
      noctalia = "noctalia";
    };
    description = ''
      User services that belong to one desktop shell, by service name. Each
      binds to the unit of its shell's desktop, as in oruc.sessionServices.
      When that desktop offers more than one shell, each service starts only
      in the session whose launcher sets ORUC_SHELL to its shell.
    '';
  };

  config = lib.mkMerge [
    {
      # A switch leaves these running on the old version, so an update never
      # restarts the panel or the keyring mid-session; the next login starts
      # the new one.
      systemd.user.services = lib.mapAttrs (_: _: {
        Unit.X-SwitchMethod = "keep-old";
      }) (config.oruc.sessionServices // config.oruc.shellServices);
    }
    (lib.mkIf (sessions.isMultiSession machine) {
      systemd.user.services =
        lib.mapAttrs (_: desktop: bindTo desktop { }) config.oruc.sessionServices
        // lib.mapAttrs (
          _: shell:
          let
            desktop = sessions.desktopOf machine shell;
          in
          bindTo desktop (
            lib.optionalAttrs (sessions.hasSeveralShells machine desktop) {
              ConditionEnvironment = "ORUC_SHELL=${shell}";
            }
          )
        ) config.oruc.shellServices;
    })
  ];
}
