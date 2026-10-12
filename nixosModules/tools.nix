# Root-facing diagnostics stay system-wide. Interactive user tools are managed
# by Home Manager, while project toolchains continue to come from direnv.
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
