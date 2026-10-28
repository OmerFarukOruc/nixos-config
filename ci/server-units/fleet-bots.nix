# Test nodes for the fleet-bots pin (nixosModules/fleet-bots-pin.nix): a stand-in
# for Tailscale's control API, and the changes that let the host's pin unit run
# against it.
#
# - `tsapi` answers api.tailscale.com over TLS (tailscale-api.py). Its
#   certificate comes from the test CA that the host already trusts for ACME.
# - `client` goes into the host's node. It points api.tailscale.com at `tsapi`,
#   puts a stand-in for `tailscale ip -4` in front of the real one in the unit's
#   path (the VM has no tailnet), and swaps the bots' public key for one whose
#   private half the test holds. The key of the host stays checkable as a file.
#
# Takes the flake inputs and the host (a nixosSystem); returns { tsapi, client } NixOS modules.
{ inputs, host }:
let
  inherit (inputs.nixpkgs) lib;
  ca = "${inputs.nixpkgs}/nixos/tests/common/acme/server";
in
{
  tsapi =
    { pkgs, ... }:
    let
      cert = pkgs.runCommand "tailscale-api-cert" { nativeBuildInputs = [ pkgs.minica ]; } ''
        minica --ca-key ${ca}/ca.key.pem --ca-cert ${ca}/ca.cert.pem --domains api.tailscale.com
        mkdir $out
        cp api.tailscale.com/cert.pem api.tailscale.com/key.pem $out/
      '';
      api = pkgs.writers.writePython3Bin "tailscale-api" {
        # The long lines are the stand-in's replies.
        flakeIgnore = [ "E501" ];
      } (builtins.readFile ./tailscale-api.py);
    in
    {
      networking.firewall.allowedTCPPorts = [ 443 ];
      systemd.services.tailscale-api = {
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          ExecStart = "${lib.getExe api} ${cert}/cert.pem ${cert}/key.pem";
          StateDirectory = "tsapi";
        };
      };
    };

  client =
    {
      config,
      nodes,
      pkgs,
      ...
    }:
    let
      botKey = pkgs.runCommand "fleet-bots-test-key" { nativeBuildInputs = [ pkgs.openssh ]; } ''
        mkdir $out
        ssh-keygen -q -t ed25519 -N "" -C test-bots -f $out/bot_key
      '';
      # The peer name of the stand-in is the host's own, so a change of the
      # name fails the test instead of passing unnoticed.
      fakeTailscale = pkgs.writeShellScriptBin "tailscale" ''
        [ "$*" = "ip -4 ${config.oruc.fleetBots.peer}" ] || { echo "unexpected: $*" >&2; exit 2; }
        [ -s /run/fake-tailscale-ip ] || { echo "no peer found" >&2; exit 1; }
        cat /run/fake-tailscale-ip
      '';
    in
    {
      # The public key of the real host, which the test cannot log in with, so
      # the test checks that it parses.
      environment.etc."fleet-bots-test/host.pub".source = host.config.oruc.fleetBots.publicKeyFile;
      networking.hosts.${nodes.tsapi.networking.primaryIPAddress} = [ "api.tailscale.com" ];
      systemd.services.fleet-bots-pin.path = lib.mkBefore [ fakeTailscale ];
      oruc.fleetBots.publicKeyFile = lib.mkForce "${botKey}/bot_key.pub";
      environment.etc = {
        "fleet-bots-test/bot_key" = {
          source = "${botKey}/bot_key";
          mode = "0600";
        };
        "fleet-bots-test/bot_key.pub".source = "${botKey}/bot_key.pub";
      };
    };
}
