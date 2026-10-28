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
      systemd.network.networks."05-test-network" = {
        matchConfig.Name = "eth1";
        address = [ "${config.networking.primaryIPAddress}/24" ];
      };
      environment.systemPackages = [ pkgs.openssl ];
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
