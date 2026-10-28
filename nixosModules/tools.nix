{ pkgs, ... }:
{
  environment.systemPackages = with pkgs; [
    curl
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
