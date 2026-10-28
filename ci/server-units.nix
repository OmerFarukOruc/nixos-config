{ inputs, host }:
let
  pkgs = inputs.nixpkgs.legacyPackages.x86_64-linux;
  acmeNodes = import ./server-units/acme.nix { inherit inputs; };
in
{
  risoluto-dev-1-units = pkgs.testers.runNixOSTest {
    name = "risoluto-dev-1-units";
    node = {
      pkgsReadOnly = false;
      specialArgs = { inherit inputs; };
    };
    nodes.acme = acmeNodes.acme;
    nodes.dnsserver = acmeNodes.dnsserver;
    nodes.machine = import ./server-units/machine.nix { inherit host acmeNodes; };
    testScript = builtins.readFile ./server-units/test.py;
  };
}
