{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (config.oruc.deskflow) role;
  server = role == "server";
  conf = "${config.xdg.configHome}/Deskflow/Deskflow.conf";
  layout = pkgs.writeText "deskflow-server.conf" ''
    section: links
    	nixos-rog:
    		right = nixos-desktop
    	nixos-desktop:
    		left = nixos-rog
    end
  '';
in
{
  options.oruc.deskflow.role = lib.mkOption {
    type = lib.types.enum [
      "server"
      "client"
    ];
    description = "Whether this PC shares its keyboard and mouse with Deskflow (server, nixos-desktop) or receives them (client, nixos-rog).";
  };

  config = lib.mkMerge [
    {
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
    }
    (lib.mkIf server {
      home.activation.deskflowServer = lib.hm.dag.entryBetween [ "reloadSystemd" ] [ "writeBoundary" ] ''
        conf=${conf}
        ini=(${lib.getExe pkgs.crudini} --ini-options=nospace --set "$conf")
        run mkdir -p ${config.xdg.configHome}/Deskflow
        run "''${ini[@]}" core coreMode 2
        run "''${ini[@]}" server externalConfig true
        run "''${ini[@]}" server externalConfigFile ${layout}
        for computer in nixos-desktop nixos-rog; do
          run "''${ini[@]}" "computer_$computer" name "$computer"
        done
        run "''${ini[@]}" log toFile true
        run "''${ini[@]}" gui startCoreWithGui true
      '';
    })
    (lib.mkIf (!server) {
      home.activation.deskflowLogToFile =
        lib.hm.dag.entryBetween [ "reloadSystemd" ] [ "writeBoundary" ]
          ''
            run mkdir -p ${config.xdg.configHome}/Deskflow
            run ${lib.getExe pkgs.crudini} --ini-options=nospace --set \
              ${conf} log toFile true
          '';
    })
  ];
}
