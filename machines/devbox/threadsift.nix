{
  config,
  lib,
  pkgs,
  ...
}:
let
  account = "threadsift";
  uid = 1100;
  subIdStart = 200000;
  subIdCount = 65536;
  subIds = "${toString subIdStart}-${toString (subIdStart + subIdCount - 1)}";
  envPublic = lib.splitString "\n" (builtins.readFile ./threadsift/env.public);
  publishedPort =
    name:
    let
      values = lib.concatMap (
        line:
        let
          found = builtins.match "${name}=([0-9]+)" line;
        in
        lib.optionals (found != null) found
      ) envPublic;
    in
    if lib.length values == 1 then
      lib.head values
    else
      throw "machines/devbox/threadsift/env.public needs exactly one ${name}=<digits> line, and has ${toString (lib.length values)}";
  publishedPorts = map publishedPort [
    "THREADSIFT_PORT"
    "THREADSIFT_TUNNEL_PORT"
  ];
  rejectedV4 = [
    "100.64.0.0/10"
    "169.254.0.0/16"
    "10.0.0.0/8"
    "172.16.0.0/12"
    "192.168.0.0/16"
  ];
  rejectedV6 = [
    "fc00::/7"
    "fe80::/10"
  ];
  rules = lib.concatMapStringsSep "\n" (rule: "-A threadsift-out ${rule}");
  reply = "-m conntrack --ctstate ESTABLISHED --ctdir REPLY -j RETURN";
  tools = [
    "iptables"
    "ip6tables"
  ];
  jumpMatches = map (owner: "OUTPUT -m owner --uid-owner ${owner} -j threadsift-out") [
    (toString uid)
    subIds
  ];
  perJump = line: lib.concatMap (tool: map (line tool) jumpMatches) tools;
  jumps = lib.concatStringsSep "\n" (
    perJump (tool: jump: "${tool} -w -C ${jump} 2>/dev/null || ${tool} -w -I ${jump}")
  );
  fenceCheck = pkgs.writeTextDir "lib/systemd/system/user@${toString uid}.service.d/50-fence.conf" ''
    [Unit]
    After=firewall.service

    [Service]
    ${lib.concatStringsSep "\n" (
      perJump (
        tool: jump: "ExecStartPre=+${config.networking.firewall.package}/bin/${tool} -w -C ${jump}"
      )
    )}
  '';
in
{
  users.groups.${account}.gid = uid;
  users.users.${account} = {
    isNormalUser = true;
    inherit uid;
    group = account;
    home = "/home/${account}";
    homeMode = "700";
    autoSubUidGidRange = false;
    subUidRanges = [
      {
        startUid = subIdStart;
        count = subIdCount;
      }
    ];
    subGidRanges = [
      {
        startGid = subIdStart;
        count = subIdCount;
      }
    ];
    description = "Threadsift Instance run user";
    linger = true;
  };
  security.sudo.extraRules = [
    {
      users = [ config.oruc.machine.user ];
      runAs = account;
      commands = [
        {
          command = "ALL";
          options = [ "NOPASSWD" ];
        }
      ];
    }
  ];

  networking.firewall.extraCommands = ''
    iptables -w -N threadsift-out 2>/dev/null || true
    ip6tables -w -N threadsift-out 2>/dev/null || true
    iptables-restore -w --noflush <<'RULES'
    *filter
    -F threadsift-out
    ${rules (
      [ reply ]
      ++
        lib.concatMap
          (resolver: [
            "-o lo -d ${resolver} -p udp --dport 53 -j RETURN"
            "-o lo -d ${resolver} -p tcp --dport 53 -j RETURN"
          ])
          [
            "127.0.0.53"
            "127.0.0.54"
          ]
      ++ map (port: "-o lo -d 127.0.0.1 -p tcp --dport ${port} -j RETURN") publishedPorts
      ++ [
        "-o lo -j REJECT"
        "-o tailscale0 -j REJECT"
      ]
      ++ map (net: "-d ${net} -j REJECT") rejectedV4
    )}
    COMMIT
    RULES
    ip6tables-restore -w --noflush <<'RULES'
    *filter
    -F threadsift-out
    ${rules (
      [
        reply
        "-o lo -j REJECT"
        "-o tailscale0 -j REJECT"
      ]
      ++ map (net: "-d ${net} -j REJECT") rejectedV6
    )}
    COMMIT
    RULES
    ${jumps}
  '';
  systemd.packages = [ fenceCheck ];
  systemd.services.linger-users = rec {
    wants = [ "home-manager-${account}.service" ];
    after = wants;
  };

  home-manager.users.${account} = {
    xdg.configFile."systemd/user/docker.service".text = "";
    systemd.user = {
      services.threadsift =
        let
          up = "${./threadsift}/threadsift-up.sh";
        in
        {
          Unit = {
            Description = "Threadsift Instance and its Cloudflare tunnel connector";
            After = [
              "network-online.target"
              "podman.socket"
            ];
            Wants = [ "network-online.target" ];
            Requires = [ "podman.socket" ];
          };
          Service = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = "${up} start";
            ExecReload = "${up} update";
            ExecStop = "${up} stop";
            Environment = [
              "PATH=${
                lib.makeBinPath [
                  pkgs.coreutils
                  pkgs.curl
                  pkgs.findutils
                ]
              }:/run/current-system/sw/bin"
            ];
            EnvironmentFile = config.sops.templates."threadsift.env".path;
            Restart = "on-failure";
            RestartSec = 30;
            TimeoutStartSec = "15min";
          };
          Install.WantedBy = [ "default.target" ];
        };
      services.threadsift-update = {
        Unit = {
          Description = "Threadsift image update";
          After = [ "threadsift.service" ];
        };
        Service = {
          Type = "oneshot";
          ExecStart = "${pkgs.systemd}/bin/systemctl --user reload threadsift.service";
        };
      };
      timers.threadsift-update = {
        Unit.Description = "Threadsift image update every 5 minutes";
        Timer = {
          OnBootSec = "5min";
          OnUnitActiveSec = "5min";
          RandomizedDelaySec = "30s";
        };
        Install.WantedBy = [ "timers.target" ];
      };
    };
  };
}
