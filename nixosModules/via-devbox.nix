{
  config,
  lib,
  pkgs,
  ...
}:
let
  netns = "via-devbox";
  hostLink = "vd-host";
  nsLink = "vd-ns";
  hostAddress = "10.98.98.1";
  nsAddress = "10.98.98.2";
  stateDir = "tailscale-${netns}";
  socket = "/run/${stateDir}/tailscaled.sock";
  ip = lib.getExe' pkgs.iproute2 "ip";
  tailscaleBypassMark = "0x80000";
  tailscaleMarkMask = "0xff0000";

  hostsLookup = lib.concatStringsSep " " config.system.nssDatabases.hosts;
  hostNsswitch = config.environment.etc."nsswitch.conf".text;
  nsNsswitch =
    lib.replaceStrings [ "hosts:     ${hostsLookup}" ] [ "hosts:     files dns" ]
      hostNsswitch;

  killSwitch = pkgs.writeText "${netns}-kill-switch.nft" ''
    table inet ${netns}
    delete table inet ${netns}
    table inet ${netns} {
      chain output {
        type filter hook output priority filter; policy accept;
        oifname "${nsLink}" meta mark & ${tailscaleMarkMask} != ${tailscaleBypassMark} drop
      }
    }
  '';

  tailscaledConfig = pkgs.writeText "tailscaled-${netns}.json" (
    builtins.toJSON {
      Version = "alpha0";
      Locked = false;
      Hostname = "${config.networking.hostName}-${netns}";
      OperatorUser = config.oruc.machine.user;
      ShieldsUp = true;
      acceptDNS = false;
      acceptRoutes = false;
      allowLANWhileUsingExitNode = false;
    }
  );

  restoreEnv = pkgs.writers.writePython3Bin "${netns}-restore-env" { } ''
    import os
    import sys

    env_file, *command = sys.argv[1:]
    with open(env_file, "rb") as saved:
        assignments = saved.read().split(b"\0")
    os.unlink(env_file)
    os.environb.clear()
    os.environb.update(a.split(b"=", 1) for a in assignments if b"=" in a)
    try:
        os.execvp(command[0], command)
    except FileNotFoundError:
        print(f"via-devbox: {command[0]}: command not found", file=sys.stderr)
        sys.exit(127)
  '';

  enter = pkgs.writeShellApplication {
    name = "${netns}-enter";
    runtimeInputs = [ pkgs.util-linux ];
    text = ''
      uid=$1 gid=$2
      shift 2
      if [[ -d /run/nscd ]]; then
        mount -t tmpfs -o mode=0755 tmpfs /run/nscd
      fi
      exec setpriv --reuid="$uid" --regid="$gid" --init-groups --reset-env \
        ${restoreEnv}/bin/${netns}-restore-env "$@"
    '';
  };

  via-devbox = pkgs.writeShellApplication {
    name = "via-devbox";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      if [[ $# -eq 0 ]]; then
        echo "usage: via-devbox COMMAND [ARG...]" >&2
        exit 2
      fi
      envFile=$(mktemp "''${XDG_RUNTIME_DIR:?}/${netns}-env.XXXXXX")
      trap 'rm -f "$envFile"' EXIT
      env -0 >"$envFile"
      /run/wrappers/bin/sudo -n ${ip} netns exec ${netns} \
        ${lib.getExe enter} "$(id -u)" "$(id -g)" "$envFile" "$@"
    '';
  };

  via-devbox-login = pkgs.writeShellApplication {
    name = "via-devbox-login";
    runtimeInputs = [
      config.services.tailscale.package
      pkgs.jq
    ];
    text = ''
      state() { tailscale --socket=${socket} status --json | jq -r .BackendState; }
      if [[ $(state) != Running ]]; then
        /run/wrappers/bin/sudo -n ${lib.getExe config.services.tailscale.package} --socket=${socket} login
        /run/wrappers/bin/sudo -n systemctl restart tailscaled-${netns}.service
        for _ in {1..30}; do
          [[ $(state) == Running ]] && break
          sleep 1
        done
      fi
      tailscale --socket=${socket} set --exit-node=devbox
      for _ in {1..15}; do
        if [[ $(tailscale --socket=${socket} status --json | jq -r '.ExitNodeStatus.Online // false') == true ]]; then
          echo "via-devbox-login: traffic leaves through devbox"
          exit 0
        fi
        sleep 1
      done
      echo "via-devbox-login: devbox is not online as the exit node" >&2
      exit 1
    '';
  };
in
{
  assertions = [
    {
      assertion = !config.security.sudo.wheelNeedsPassword;
      message = "via-devbox enters its namespace through sudo -n, so wheel needs passwordless sudo.";
    }
    {
      assertion = config.networking.nftables.enable;
      message = "via-devbox loads its kill switch with nft and runs its node in nftables mode.";
    }
  ];

  environment.systemPackages = [
    via-devbox
    via-devbox-login
  ];

  environment.etc = {
    "netns/${netns}/resolv.conf".text = ''
      nameserver 1.1.1.1
      nameserver 9.9.9.9
    '';
    "netns/${netns}/nsswitch.conf".text =
      assert lib.assertMsg (nsNsswitch != hostNsswitch) "nsswitch.conf has no hosts line to replace";
      nsNsswitch;
  };

  networking.nat = {
    enable = true;
    internalInterfaces = [ hostLink ];
  };

  networking.firewall = {
    filterForward = true;
    extraForwardRules = ''
      iifname "docker0" accept
      iifname "br-*" accept
      iifname "podman*" accept
    '';
  };

  networking.networkmanager.unmanaged = [ "interface-name:${hostLink}" ];

  systemd.services."${netns}-netns" = {
    description = "Network namespace whose traffic leaves through devbox";
    wantedBy = [ "multi-user.target" ];
    path = [
      pkgs.iproute2
      pkgs.nftables
    ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      [[ -e /run/netns/${netns} ]] || ip netns add ${netns}
      ip link show ${hostLink} &>/dev/null ||
        ip link add ${hostLink} type veth peer name ${nsLink} netns ${netns}
      ip address replace ${hostAddress}/30 dev ${hostLink}
      ip link set ${hostLink} up
      ip netns exec ${netns} nft -f ${killSwitch}
      ip -n ${netns} link set lo up
      ip -n ${netns} address replace ${nsAddress}/30 dev ${nsLink}
      ip -n ${netns} link set ${nsLink} up
      ip -n ${netns} route replace default via ${hostAddress}
    '';
  };

  # tailscaled configures DNS through resolved or NetworkManager on the system
  # bus, which is the host's and would rewrite the host's DNS for an interface
  # index that only exists in the namespace. Without the bus it falls back to
  # /etc/resolv.conf, which the bind mount keeps read-only.
  oruc.failurePopupUnits = [ "tailscaled-${netns}" ];

  systemd.services."tailscaled-${netns}" = {
    description = "Tailscale node of the ${netns} namespace, with devbox as its exit node";
    bindsTo = [ "${netns}-netns.service" ];
    after = [ "${netns}-netns.service" ];
    wantedBy = [ "multi-user.target" ];
    path = [ pkgs.iproute2 ];
    environment.TS_DEBUG_FIREWALL_MODE =
      config.systemd.services.tailscaled.environment.TS_DEBUG_FIREWALL_MODE;
    serviceConfig = {
      ExecStart = lib.concatStringsSep " " [
        (lib.getExe' config.services.tailscale.package "tailscaled")
        "--config=${tailscaledConfig}"
        "--statedir=/var/lib/${stateDir}"
        "--socket=${socket}"
        "--port=0"
        "--tun=tailscale0"
      ];
      NetworkNamespacePath = "/run/netns/${netns}";
      BindReadOnlyPaths = [ "/etc/netns/${netns}/resolv.conf:/etc/resolv.conf" ];
      InaccessiblePaths = [ "/run/dbus" ];
      RuntimeDirectory = stateDir;
      StateDirectory = stateDir;
      StateDirectoryMode = "0700";
      Restart = "on-failure";
      RestartSec = 5;
    };
  };
}
