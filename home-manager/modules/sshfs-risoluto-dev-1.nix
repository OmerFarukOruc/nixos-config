# Mounts the whole of risoluto-dev-1 read-only, as oruc over Tailscale SSH, so
# local apps open its paths: /tmp/x on the box is ~/remote/risoluto-dev-1/tmp/x
# here. Keep the unit name sshfs-risoluto-dev-1.service, because dotfiles'
# `ropen` starts it when the mount is down.
#
# The mount point is under $XDG_RUNTIME_DIR and ~/remote/risoluto-dev-1 is a
# symlink to it, because Baloo, find and rg walk the home folder without
# following symlinks; a mount inside the home folder would have them crawl the
# box's disk. After a suspend or a network drop, a read can wait up to 45
# seconds (ServerAliveInterval times ServerAliveCountMax) before sshfs drops the
# dead connection; `reconnect` then opens a new one on the next read.
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
  # ropen reports its errors with notify-send when no terminal shows them.
  home.packages = [ pkgs.libnotify ];

  systemd.user.services.sshfs-risoluto-dev-1 = {
    Unit = {
      Description = "sshfs mount of risoluto-dev-1 at ~/remote/risoluto-dev-1";
      # The user manager has no network-online.target; a start before the
      # network is up fails and Restart tries again.
      StartLimitIntervalSec = 0;
      # A switch that changes NetworkManager stops it until activation ends,
      # so a restart then cannot reach the box: it held activation for the 30 s
      # of ExecStartPost and left the unit waiting to restart, which fails
      # deploy.sh's user service check (exit 75, journal 2026-10-26 20:08).
      # The running mount keeps working and reconnects; the next start uses
      # the new unit.
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
      # The start returns once the mount is up, so `ropen -f` can open a path
      # right after it starts the unit.
      ExecStartPost = "${coreutils "timeout"} 30 ${waitForMount} ${mount}";
      ExecStopPost = "-${fusermount} -uz ${mount}";
      Restart = "on-failure";
      RestartSec = 30;
    };
    Install.WantedBy = [ "default.target" ];
  };
}
