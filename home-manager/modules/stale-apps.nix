{
  lib,
  osConfig,
  pkgs,
  ...
}:
let
  staleApps = pkgs.writeShellApplication {
    name = "stale-apps";
    runtimeInputs = [
      osConfig.nix.package
      pkgs.coreutils
      pkgs.libnotify
    ];
    text = builtins.readFile ./stale-apps.sh;
  };
  systemctl = lib.getExe' pkgs.systemd "systemctl";
in
{
  systemd.user.services.stale-apps = {
    Unit.Description = "Name desktop apps that still run a version an update replaced";
    Service = {
      Type = "oneshot";
      ExecStart = lib.getExe staleApps;
    };
  };

  home.activation.staleApps = lib.hm.dag.entryAfter [ "reloadSystemd" ] ''
    runtime=''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}
    if [[ ! -v DRY_RUN && -S $runtime/bus ]]; then
      XDG_RUNTIME_DIR=$runtime ${systemctl} --user start --no-block stale-apps.service \
        || warnEcho "could not start stale-apps.service; apps that still run an old version go unnamed."
    fi
    unset runtime
  '';
}
