{ pkgs, ... }:
{
  # Scripts from other repositories run with their `#!/bin/bash` shebangs.
  # envfs serves /bin and /usr/bin from the PATH of the calling process.
  services.envfs.enable = true;
  # Chromium overwrites its environ for the process title, so envfs sees no
  # PATH for Electron apps. detect-libc in ChatGPT's file watcher then falls
  # through to process.report.getReport(), which crashes Electron in a worker.
  services.envfs.extraFallbackPathCommands = "ln -s ${pkgs.glibc.bin}/bin/ldd $out/ldd";
}
