{
  config,
  lib,
  ...
}:
let
  inherit (config.oruc) machine;
  ports = lib.sort lib.lessThan (lib.unique config.oruc.ownerLoopbackPorts);
  portList = separator: lib.concatMapStringsSep separator toString ports;
  nftables = config.networking.nftables.enable;
  iptables = config.networking.firewall.enable && !nftables;
in
{
  options.oruc.ownerLoopbackPorts = lib.mkOption {
    type = lib.types.listOf lib.types.port;
    default = [ ];
    description = "Loopback TCP ports that only root and the machine's user may connect to, such as a DevTools port, which has no password.";
  };

  config = lib.mkIf (ports != [ ]) {
    assertions = [
      {
        assertion = !iptables || lib.length ports <= 15;
        message = "oruc.ownerLoopbackPorts holds ${toString (lib.length ports)} ports, and an iptables multiport match takes 15.";
      }
    ];

    # The ruleset check runs in the build sandbox, which has no such user.
    networking.nftables.preCheckRuleset = lib.mkIf nftables ''
      sed -i 's/"${machine.user}"/"nobody"/' ruleset.conf
    '';
    networking.nftables.tables.owner-loopback = lib.mkIf nftables {
      family = "inet";
      content = ''
        chain output {
          type filter hook output priority filter; policy accept;
          oifname "lo" tcp dport { ${portList ", "} } meta skuid != { 0, "${machine.user}" } reject
        }
      '';
    };

    networking.firewall.extraCommands = lib.mkIf iptables ''
      owner_loopback_rules='*filter
      -F owner-loopback-out
      -A owner-loopback-out -p tcp -m multiport ! --dports ${portList ","} -j RETURN
      -A owner-loopback-out -m owner --uid-owner 0 -j RETURN
      -A owner-loopback-out -m owner --uid-owner ${machine.user} -j RETURN
      -A owner-loopback-out -p tcp -j REJECT --reject-with tcp-reset
      COMMIT'
      for ipt in iptables ip6tables; do
        "$ipt" -w -N owner-loopback-out 2> /dev/null || true
        "$ipt-restore" -w --noflush <<< "$owner_loopback_rules"
        "$ipt" -w -C OUTPUT -o lo -p tcp --syn -j owner-loopback-out 2> /dev/null ||
          "$ipt" -w -I OUTPUT -o lo -p tcp --syn -j owner-loopback-out
      done
    '';
  };
}
