{ inputs, host }:
let
  inherit (inputs.nixpkgs) lib;
  pkgs = inputs.nixpkgs.legacyPackages.x86_64-linux;
  acmeNodes = import ./server-units/acme.nix { inherit inputs; };
  nixpkgsTests = "${inputs.nixpkgs}/nixos/tests/common";
in
{
  devbox-desktop = pkgs.testers.runNixOSTest {
    name = "devbox-desktop";
    node = {
      pkgsReadOnly = false;
      specialArgs = { inherit inputs; };
    };
    nodes.acme = acmeNodes.acme;
    nodes.dnsserver = acmeNodes.dnsserver;
    nodes.machine = {
      imports = [
        (import ./server-units/machine.nix { inherit host acmeNodes; })
        ./server-desktop/machine.nix
      ];
    };
    nodes.client = {
      imports = [
        "${nixpkgsTests}/x11.nix"
        "${nixpkgsTests}/user-account.nix"
        ./server-desktop/client.nix
      ];
    };
    testScript =
      { nodes, ... }:
      import ./box-names.nix host
      + ''
        SD_PUBLIC_ADDRESS = "${nodes.machine.networking.primaryIPAddress}"
        SD_TAILNET_ADDRESS = "${(lib.head nodes.machine.networking.interfaces.eth2.ipv4.addresses).address}"
      ''
      + builtins.readFile ./server-desktop/test.py;
  };
}
