{
  description = "The desktop shell OmerFarukOruc's NixOS hosts compile, built the same way for a public Cachix cache";

  # The hosts lock nixpkgs to nixos-unstable and make DMS follow it, so a build
  # here with the same nixpkgs revision and the same release tag has the host's
  # store path. Noctalia comes from nixpkgs on the hosts, so the NixOS cache
  # holds it.
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    # A release tag, which scripts/pin-release.sh moves.
    dms = {
      url = "github:AvengeMedia/DankMaterialShell/v1.6.3";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    { dms, ... }:
    {
      # MIT licensed.
      packages.x86_64-linux.dms = dms.packages.x86_64-linux.default;
    };
}
