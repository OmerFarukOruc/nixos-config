{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (config.oruc.deskflow) role;
  server = role == "server";
  dir = "${config.xdg.configHome}/Deskflow";
  computers = {
    nixos-desktop = { };
    nixos-rog.aliases = "laptop-windows";
  };
  layout = pkgs.writeText "deskflow-server.conf" ''
    section: links
    	nixos-rog:
    		right = nixos-desktop
    	nixos-desktop:
    		left = nixos-rog
    end
  '';
  settings = {
    log.toFile = true;
  }
  // lib.optionalAttrs server (
    {
      core.coreMode = 2;
      server = {
        externalConfig = true;
        externalConfigFile = "${layout}";
      };
      gui.startCoreWithGui = true;
    }
    // lib.mapAttrs' (
      name: computer: lib.nameValuePair "computer_${name}" ({ inherit name; } // computer)
    ) computers
  );
in
{
  options.oruc.deskflow.role = lib.mkOption {
    type = lib.types.enum [
      "server"
      "client"
    ];
    description = "Whether this PC shares its keyboard and mouse with Deskflow (server, nixos-desktop) or receives them (client, nixos-rog).";
  };

  config = {
    # A client on Wayland types through the remote desktop portal, which
    # Plasma has and niri does not, so Deskflow starts at a Plasma login only.
    # The portal reads the app ID from the unit name (app-<ID>.service), and
    # Plasma names the app in its remote control notice by that ID. Any other
    # unit name shows the notice as "An unidentifiable application".
    systemd.user.services."app-org.deskflow.deskflow" = {
      Unit = {
        Description = if server then "Deskflow server" else "Deskflow client of nixos-desktop";
        After = [ "plasma-workspace.target" ];
        PartOf = [ "plasma-workspace.target" ];
        RefuseManualStart = true;
        RefuseManualStop = true;
      };
      Service = {
        ExecStart = lib.getExe pkgs.deskflow;
        Restart = "on-failure";
        RestartSec = 5;
        # Deskflow exits 5 when another instance runs, such as one started from
        # the menu. A restart would only raise that instance's window again.
        SuccessExitStatus = 5;
      };
      Install.WantedBy = [ "plasma-workspace.target" ];
    };

    home.activation.deskflow = lib.hm.dag.entryBetween [ "reloadSystemd" ] [ "writeBoundary" ] ''
      run mkdir -p ${dir}
      run ${lib.getExe pkgs.crudini} --ini-options=nospace --merge ${dir}/Deskflow.conf \
        < ${pkgs.writeText "Deskflow.conf" (lib.generators.toINI { } settings)}
    '';
  };
}
