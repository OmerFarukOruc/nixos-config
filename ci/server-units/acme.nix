# Test nodes that let the host's real certificate orders succeed in the units
# test: nixpkgs' test ACME server (pebble) and a DNS server for the DNS-01
# challenge (pebble-challtestsrv), set up as nixos/tests/acme/dns01.nix does.
# The host's certificates use Cloudflare for the challenge, which no VM can
# reach, so the client module swaps lego's DNS provider for its exec provider,
# a script that puts the challenge record into the test DNS server. The
# Cloudflare wiring itself is not covered; a real order at the cutover is.
#
# Takes the flake inputs; returns { acme, dnsserver, client } NixOS modules for
# the test's nodes. `client` goes into the host's node.
{ inputs }:
let
  inherit (inputs.nixpkgs) lib;
  commonAcme = "${inputs.nixpkgs}/nixos/tests/common/acme";
in
{
  acme =
    { nodes, ... }:
    {
      imports = [ "${commonAcme}/server" ];
      networking.nameservers = lib.mkForce [ nodes.dnsserver.networking.primaryIPAddress ];
    };

  dnsserver =
    { nodes, pkgs, ... }:
    {
      networking = {
        firewall.allowedTCPPorts = [
          8055
          53
        ];
        firewall.allowedUDPPorts = [ 53 ];
        hostName = "dnsserver";
        domain = "test";
      };
      systemd.services.pebble-challtestsrv = {
        description = "Pebble ACME challenge test server";
        wantedBy = [ "network.target" ];
        serviceConfig = {
          ExecStart = "${pkgs.pebble}/bin/pebble-challtestsrv -dns01 ':53' -defaultIPv6 '' -defaultIPv4 '${nodes.machine.networking.primaryIPAddress}'";
          AmbientCapabilities = [ "CAP_NET_BIND_SERVICE" ];
        };
      };
    };

  client =
    { config, pkgs, ... }:
    let
      dnsHook = pkgs.writeShellScript "dns-hook.sh" ''
        set -euo pipefail
        if [ "$1" = "present" ]; then
          ${pkgs.curl}/bin/curl --fail --data "{\"host\": \"$2\", \"value\": \"$3\"}" http://dnsserver.test:8055/set-txt
        else
          ${pkgs.curl}/bin/curl --fail --data "{\"host\": \"$2\"}" http://dnsserver.test:8055/clear-txt
        fi
      '';
    in
    {
      imports = [ "${commonAcme}/client" ];
      # The host's public network file (10-public.network) matches every
      # ethernet interface, eth1 of the test network too, and gives it the
      # address of the public interface. A file that sorts before it takes eth1.
      systemd.network.networks."05-test-network" = {
        matchConfig.Name = "eth1";
        address = [ "${config.networking.primaryIPAddress}/24" ];
      };
      # For the checks of the test script.
      environment.systemPackages = [ pkgs.openssl ];
      # Each order copies its files into out/, then chmods and chowns them for
      # the web server's group. Until that chmod, the files are 0600 and Caddy
      # cannot read them. Orders that share an account run at the same time,
      # except the first, which runs alone. An order that is done restarts
      # Caddy while the others are in that window. A chmod of out/ that waits,
      # with a longer wait for each order, makes the overlap certain instead of
      # rare. The line it logs after the wait lets the test check that the wait
      # still happens after a nixpkgs move.
      systemd.services = lib.listToAttrs (
        lib.imap1 (
          i: name:
          lib.nameValuePair "acme-order-renew-${name}" {
            path = lib.mkBefore [
              (pkgs.writeShellScriptBin "chmod" ''
                if [ "$#" -eq 3 ] && [ "$3" = out ]; then
                  sleep ${toString (10 * i)} && echo "test: chmod of out waited ${toString (10 * i)} s" >&2
                fi
                exec ${pkgs.coreutils}/bin/chmod "$@"
              '')
            ];
          }
        ) (lib.attrNames config.oruc.tailnetWeb.sites)
      );
      security.acme.defaults = {
        dnsProvider = lib.mkForce "exec";
        credentialFiles = lib.mkForce { };
        dnsPropagationCheck = false;
        environmentFile = pkgs.writeText "exec.env" ''
          EXEC_PATH=${dnsHook}
          EXEC_POLLING_INTERVAL=1
          EXEC_PROPAGATION_TIMEOUT=1
          EXEC_SEQUENCE_INTERVAL=1
        '';
      };
    };
}
