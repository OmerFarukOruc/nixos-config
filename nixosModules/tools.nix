# Root-facing diagnostics stay system-wide. Home Manager manages the
# interactive user tools, and direnv supplies project toolchains.
{ pkgs, ... }:
{
  environment.systemPackages = with pkgs; [
    curl
    # deploy.sh shows with it what a new system changes.
    dix
    lsof
    mtr
    nmap
    nvme-cli
    rsync
    smartmontools
    strace
    tcpdump
  ];
}
