{ lib, pkgs, ... }:
let
  mount = "%t/sshfs/risoluto-dev-1";
  fusermount = "/run/wrappers/bin/fusermount3";
  coreutils = name: lib.getExe' pkgs.coreutils name;
  waitForMount = pkgs.writeShellScript "sshfs-wait-for-mount" ''
    until ${lib.getExe' pkgs.util-linux "mountpoint"} -q "$1"; do
      ${coreutils "sleep"} 0.2
    done
  '';
in
{
  home.packages = [ pkgs.libnotify ];

  systemd.user.services.sshfs-risoluto-dev-1 = {
    Unit = {
      Description = "sshfs mount of risoluto-dev-1 at ~/remote/risoluto-dev-1";
      StartLimitIntervalSec = 0;
      X-SwitchMethod = "keep-old";
    };
    Service = {
      Type = "exec";
      ExecStartPre = [
        "-${fusermount} -uz ${mount}"
        "${coreutils "mkdir"} -p ${mount} %h/remote"
        "${coreutils "ln"} -sfn ${mount} %h/remote/risoluto-dev-1"
      ];
      ExecStart = "${lib.getExe' pkgs.sshfs "sshfs"} -f oruc@risoluto-dev-1:/ ${mount} -o ro,reconnect,idmap=user,BatchMode=yes,ConnectTimeout=10,ServerAliveInterval=15,ServerAliveCountMax=3";
      ExecStartPost = "${coreutils "timeout"} 30 ${waitForMount} ${mount}";
      ExecStopPost = "-${fusermount} -uz ${mount}";
      Restart = "on-failure";
      RestartSec = 30;
    };
    Install.WantedBy = [ "default.target" ];
  };
}
