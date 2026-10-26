{
  config,
  lib,
  pkgs,
  ...
}:
let
  fallbackPath = lib.findFirst (
    o: lib.hasPrefix "fallback-path=" o
  ) (throw "envfs: no fallback-path option") config.fileSystems."/usr/bin".options;
in
{
  # Scripts from other repositories run with their `#!/bin/bash` shebangs.
  # envfs serves /bin and /usr/bin from the PATH of the calling process.
  services.envfs.enable = true;
  # Chromium overwrites its environ for the process title, so envfs sees no
  # PATH for Electron apps. detect-libc in ChatGPT's file watcher then falls
  # through to process.report.getReport(), which crashes Electron in a worker.
  services.envfs.extraFallbackPathCommands = "ln -s ${pkgs.glibc.bin}/bin/ldd $out/ldd";

  # A switch only remounts a mount whose options change, and envfs ignores a
  # remount, so a new fallback dir would wait for the next boot. A new device
  # makes the switch restart the mount. envfs ignores the device. A device
  # other than "none" would also give the mount an fsck pass.
  fileSystems."/usr/bin" = {
    device = lib.mkForce "envfs-${builtins.substring 0 12 (builtins.hashString "sha256" fallbackPath)}";
    noCheck = true;
  };

  # envfs 1.2.0 keeps running after an unmount and, on SIGTERM, unmounts
  # /usr/bin whoever mounted it. Kill the old daemon after the old mount is
  # gone and before the new one starts. SIGKILL skips that unmount.
  systemd.services.envfs-reap = {
    description = "Stop envfs daemons left over from an unmounted /usr/bin";
    wantedBy = [ "usr-bin.mount" ];
    before = [ "usr-bin.mount" ];
    partOf = [ "usr-bin.mount" ];
    unitConfig.DefaultDependencies = false;
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      if ${pkgs.util-linux}/bin/mountpoint -q /usr/bin; then
        exit 0
      fi
      procs=/sys/fs/cgroup/system.slice/usr-bin.mount/cgroup.procs
      [ -r "$procs" ] || exit 0
      while read -r pid; do
        echo "killing envfs daemon $pid"
        kill -KILL "$pid" || true
      done < "$procs"
      for _ in $(seq 50); do
        [ -n "$(cat "$procs")" ] || exit 0
        sleep 0.1
      done
      echo "envfs daemons still running: $(tr '\n' ' ' < "$procs")" >&2
      exit 1
    '';
  };
}
