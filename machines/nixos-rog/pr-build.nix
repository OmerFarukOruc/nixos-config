# The host-systems-build check (.github/workflows/host-systems-build.yml) logs
# in from GitHub Actions over the tailnet with a key of its own. That key can
# only run scripts/pr-build.sh, which builds the systems a PR changes;
# restrict turns off the terminal and every forwarding.
{ config, pkgs, ... }:
let
  prBuild = pkgs.writeShellApplication {
    name = "nixos-config-pr-build";
    # heavy comes from oruc's Home Manager profile, which the login shell's
    # PATH holds.
    runtimeInputs = [
      config.nix.package
      # systemd-ac-power.
      config.systemd.package
    ]
    ++ (with pkgs; [
      coreutils
      curl
      findutils
      git
      jq
      util-linux
    ]);
    text = builtins.readFile ../../scripts/pr-build.sh;
  };
in
{
  users.users.oruc.openssh.authorizedKeys.keys = [
    ''restrict,command="${prBuild}/bin/nixos-config-pr-build" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPZnHWnI45v1HEEC9C093pkPhpd0qnvCI33hXxAcyrDj host-systems-build@github-actions''
  ];

  # The lock that the check and the updater (auto-update.nix) take around their
  # evaluations and builds.
  systemd.tmpfiles.rules = [ "f /run/nixos-config-build.lock 0600 oruc users -" ];
}
