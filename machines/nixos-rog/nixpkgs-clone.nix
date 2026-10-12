# A local nixpkgs clone for reading sources, fetched hourly on AC power.
{ pkgs, ... }:
{
  systemd.services.nixpkgs-clone = {
    description = "Fetch the nixpkgs clone in /var/cache/nixpkgs";
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];
    unitConfig.ConditionACPower = true;
    path = [ pkgs.git ];
    # An interrupted clone leaves .git without a commit, so it starts over.
    script = ''
      if ! git rev-parse --quiet --verify HEAD >/dev/null 2>&1; then
        find . -mindepth 1 -delete
        git clone https://github.com/NixOS/nixpkgs.git .
      fi
      git fetch --prune origin
      git reset --quiet --hard origin/HEAD
    '';
    serviceConfig = {
      Type = "oneshot";
      User = "oruc";
      CacheDirectory = "nixpkgs";
      WorkingDirectory = "/var/cache/nixpkgs";
      Nice = 19;
      IOSchedulingClass = "idle";
    };
  };

  oruc.keptPaths = [ "/var/cache/nixpkgs" ];

  systemd.timers.nixpkgs-clone = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "hourly";
      Persistent = true;
      RandomizedDelaySec = "5min";
    };
  };
}
