# The unit that deploys the newest main to its own host, shared by nixos-rog's
# updater (machines/nixos-rog/auto-update.nix) and a server's self-deploy
# (deploy-host.nix). Not a module: it takes config and pkgs, then the unit's
# name, script and user, and returns a systemd service definition. The script
# sources scripts/lib/pull-main.sh, which DEPLOY_LIB names.
{ config, pkgs }:
{
  name,
  script,
  user,
  # Packages the script needs beyond the shared ones.
  extraPath ? [ ],
  # The file a GitHub token is read from, loaded as the credential
  # github-token (scripts/lib/pull-main.sh, github_config), or null.
  githubTokenFile ? null,
}:
{
  wants = [ "network-online.target" ];
  after = [ "network-online.target" ];
  # The service runs the switch itself; restarting it then would kill deploy.sh
  # before it confirms the new system.
  restartIfChanged = false;
  # A rollback to a system without this unit must not stop it mid-deploy.
  unitConfig.X-StopOnRemoval = false;
  # NixOS adds coreutils, findutils, grep, sed and systemd to every service.
  # deploy.sh calls sudo, which lives in /run/wrappers/bin.
  path = [
    "/run/wrappers"
    config.nix.package
  ]
  ++ (with pkgs; [
    bash
    curl
    diffutils
    # deploy.sh's system diff.
    dix
    gawk
    # deploy.sh asks gh which pull request merged a running release.
    gh
    git
    jq
    rsync
    # flock for deploy.sh's lock.
    util-linux
  ])
  ++ extraPath;
  environment = {
    DEPLOY_REPOSITORY = "https://github.com/OmerFarukOruc/nixos-config.git";
    DEPLOY_LIB = "${../scripts/lib/pull-main.sh}";
  };
  serviceConfig = {
    Type = "oneshot";
    # Without a limit one hung network call keeps the unit active, and the timer
    # never starts it again. The slowest deploy of 119 runs of the old updater
    # on nixos-rog took 659 s (journal, 2026-10-16 to 2026-10-23); the rest is
    # room for compiling the packages that no cache holds. A kill sends the
    # script SIGTERM, and its trap reports. A kill during deploy.sh leaves the
    # rollback timer to restore the previous system.
    TimeoutStartSec = "3h";
    # Slows the run above 12 GiB and never kills it, so the script's traps still
    # report. A MemoryMax kill would skip them. The old updater, which also
    # evaluated every host, peaked at 7.5 GiB (journal, 2026-10-26).
    MemoryHigh = "12G";
    User = user;
    StateDirectory = name;
    RuntimeDirectory = name;
    RuntimeDirectoryMode = "0700";
    UMask = "0077";
    SyslogIdentifier = name;
    ExecStart = "${pkgs.bash}/bin/bash ${script}";
  }
  // (
    if githubTokenFile == null then { } else { LoadCredential = [ "github-token:${githubTokenFile}" ]; }
  );
}
