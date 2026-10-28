# A NixOS test of the streamed desktop of risoluto-dev-1
# (nixosModules/streamed-desktop.nix): the host's own modules on `machine`, an
# RDP client on `client`, and the test CA of the units test. `machine` has a
# second network card that the test renames to tailscale0, so a connection
# through eth1 stands for the public interface and one through tailscale0 for
# the tailnet. Needs KVM. Takes the inputs and the host (a nixosSystem);
# returns the flake checks.
{ inputs, host }:
let
  inherit (inputs.nixpkgs) lib;
  pkgs = inputs.nixpkgs.legacyPackages.x86_64-linux;
  acmeNodes = import ./server-units/acme.nix { inherit inputs; };
  nixpkgsTests = "${inputs.nixpkgs}/nixos/tests/common";
in
{
  risoluto-dev-1-desktop = pkgs.testers.runNixOSTest {
    name = "risoluto-dev-1-desktop";
    # The host sets nixpkgs.config and overlays itself.
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
      ''
        SD_PUBLIC_ADDRESS = "${nodes.machine.networking.primaryIPAddress}"
        SD_TAILNET_ADDRESS = "${(lib.head nodes.machine.networking.interfaces.eth2.ipv4.addresses).address}"
      ''
      + builtins.readFile ./server-desktop/test.py;
  };
}
