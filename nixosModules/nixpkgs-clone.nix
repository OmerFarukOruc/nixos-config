# A local nixpkgs master clone for reading sources, fetched hourly on AC power.
# The hosts that agents run on import it, so a lookup reads the clone on the
# host it runs on. A failed fetch shows the popup of nixosModules/monitoring.nix.
{ pkgs, ... }:
{
  systemd.services.nixpkgs-clone = {
    description = "Fetch the nixpkgs clone in /var/cache/nixpkgs";
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];
    # Also true on a host with no battery.
    unitConfig.ConditionACPower = true;
    onFailure = [ "notify-failure@%p.service" ];
    path = [ pkgs.git ];
    # An interrupted clone leaves .git without a commit, so it starts over.
    script = ''
      if ! git rev-parse --quiet --verify HEAD >/dev/null 2>&1; then
        find . -mindepth 1 -delete
        git clone --single-branch --branch master https://github.com/NixOS/nixpkgs.git .
      fi
      # Migrate existing clones without deleting their refs or history.
      git remote set-branches origin master
      git fetch --prune origin
      git reset --quiet --hard origin/master
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
  systemd.timers.nixpkgs-clone = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "hourly";
      Persistent = true;
      RandomizedDelaySec = "5min";
    };
  };
}
