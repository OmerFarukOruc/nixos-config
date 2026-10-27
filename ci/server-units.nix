# A NixOS test that boots the host's own configuration and refuses a failed
# unit. A unit that fails during a switch makes switch-to-configuration exit 4,
# which deploy.sh rolls back, so a host with a failed unit after boot would roll
# back every deploy. smartd failed on the virtual disk that way before the box
# turned it off. The boot test of ci/server-boot.nix cannot hold this check,
# because its booted machine has a read-only /nix/store and no database of its
# closure, so the Home Manager units fail there for reasons that the box does
# not have. This test uses qemu-vm's standard store, which is writable and
# registered.
#
# Takes the inputs and the host (a nixosSystem); returns the flake checks.
{ inputs, host }:
let
  pkgs = inputs.nixpkgs.legacyPackages.x86_64-linux;
  acmeNodes = import ./server-units/acme.nix { inherit inputs; };
in
{
  risoluto-dev-1-units = pkgs.testers.runNixOSTest {
    name = "risoluto-dev-1-units";
    # The host sets nixpkgs.config and overlays itself.
    node = {
      pkgsReadOnly = false;
      specialArgs = { inherit inputs; };
    };
    nodes.acme = acmeNodes.acme;
    nodes.dnsserver = acmeNodes.dnsserver;
    # The host's modules are those of mkMachine in machines/inventory.nix. The
    # acme client and the sops stub are the test's additions.
    nodes.machine = {
      imports = [
        acmeNodes.client
        ../nixosModules/default.nix
        { oruc.machine = host.config.oruc.machine; }
        ../machines/risoluto-dev-1/configuration.nix
        ../machines/risoluto-dev-1/hardware-configuration.nix
        # Test values for the sops file, as in the boot test.
        ./server-boot/modules/sops.nix
      ];
      virtualisation = {
        memorySize = 2048;
        # The host names /dev/vda as Limine's BIOS device, and qemu-vm sets the
        # same option from this one.
        bootLoaderDevice = "/dev/vda";
      };
    };
    testScript = builtins.readFile ./server-units/test.py;
  };
}
