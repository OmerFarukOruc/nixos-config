{ config, pkgs }:
{
  name,
  script,
  user,
  extraPath ? [ ],
  githubTokenFile ? null,
}:
{
  wants = [ "network-online.target" ];
  after = [ "network-online.target" ];
  restartIfChanged = false;
  unitConfig.X-StopOnRemoval = false;
  path = [
    "/run/wrappers"
    config.nix.package
  ]
  ++ (with pkgs; [
    bash
    curl
    diffutils
    dix
    gawk
    gh
    git
    jq
    rsync
    util-linux
  ])
  ++ extraPath;
  environment = {
    DEPLOY_REPOSITORY = "https://github.com/OmerFarukOruc/nixos-config.git";
    DEPLOY_LIB = "${../scripts/lib/pull-main.sh}";
  };
  serviceConfig = {
    Type = "oneshot";
    TimeoutStartSec = "3h";
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
