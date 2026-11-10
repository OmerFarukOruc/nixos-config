{
  config,
  inputs,
  pkgs,
  llmAgents,
  ...
}:
let
  secret = name: config.sops.placeholder.${name};
  slFactoryFenceTeardown = ''
    ip46tables -D OUTPUT -m owner --uid-owner sl-factory -j sl-factory-out 2>/dev/null || true
    ip46tables -F sl-factory-out 2>/dev/null || true
    ip46tables -X sl-factory-out 2>/dev/null || true
  '';
in
{
  imports = [
    inputs.disko.nixosModules.disko
    inputs.sops-nix.nixosModules.sops
    ./disk.nix
    ./services.nix
    ../../nixosModules/agent-runtime.nix
    ../../nixosModules/agents.nix
    ../../nixosModules/envfs.nix
    ../../nixosModules/rootless-containers.nix
    ../../nixosModules/tailnet-web.nix
  ];

  boot.loader.efi.canTouchEfiVariables = false;

  services.qemuGuest.enable = true;

  services.smartd.enable = false;

  oruc.autoUpgrade = {
    enable = true;
    reboot = true;
  };

  oruc.deploy = {
    sessionIgnore = [
      "amp-runner.service"
      "cliproxy*.service"
      "cursor-worker.service"
      "docker.service"
      "herdr-*.service"
      "openchamber.service"
    ];
  };

  sops = {
    defaultSopsFile = ../../secrets/devbox.yaml;
    secrets = {
      omer-password-hash.neededForUsers = true;
      root-password-hash.neededForUsers = true;
      network-ipv4-address = { };
      network-ipv4-gateway = { };
      network-ipv6-address = { };
      network-dns-1 = { };
      network-dns-2 = { };
      network-dns-3 = { };
      cloudflare-acme-dns-token.sopsFile = ../../secrets/devbox-acme.yaml;
    };
    templates."10-public.network" = {
      group = "systemd-network";
      mode = "0440";
      restartUnits = [ "systemd-networkd.service" ];
      content = ''
        [Match]
        Type=ether
        Name=en* eth*

        [Network]
        DHCP=no
        IPv6AcceptRA=no
        Address=${secret "network-ipv4-address"}
        Address=${secret "network-ipv6-address"}
        DNS=${secret "network-dns-1"}
        DNS=${secret "network-dns-2"}
        DNS=${secret "network-dns-3"}

        [Route]
        Gateway=${secret "network-ipv4-gateway"}
        GatewayOnLink=yes

        [Route]
        Gateway=fe80::1
      '';
    };
  };

  oruc.telemetry = {
    enable = true;
    environment = "development";
    endpoint = "signoz.statuslantern.com:4317";
    insecure = true;
    filesystemMounts = [ "/tmp" ];
    certificates.aws-agent = "${
      config.users.users.${config.oruc.machine.user}.home
    }/.aws/rolesanywhere/leaf.pem";
  };

  networking = {
    useDHCP = false;
    useNetworkd = true;
  };
  services.resolved.enable = true;
  environment.etc."systemd/network/10-public.network".source =
    config.sops.templates."10-public.network".path;
  environment.etc."ampcode/managed-settings.json".text = builtins.toJSON {
    "amp.remoteThreadCreation.enabled" = true;
  };

  users.mutableUsers = false;
  users.groups.${config.oruc.machine.user}.gid = 1003;
  users.users.${config.oruc.machine.user} = {
    uid = 1003;
    group = config.oruc.machine.user;
    autoSubUidGidRange = false;
    subUidRanges = [
      {
        startUid = 100000;
        count = 65536;
      }
    ];
    subGidRanges = [
      {
        startGid = 100000;
        count = 65536;
      }
    ];
    linger = true;
    hashedPasswordFile = config.sops.secrets.omer-password-hash.path;
  };
  users.users.root.hashedPasswordFile = config.sops.secrets.root-password-hash.path;

  users.groups.sl-factory = { };
  users.users.sl-factory = {
    isNormalUser = true;
    group = "sl-factory";
    home = "/home/sl-factory";
    homeMode = "700";
    autoSubUidGidRange = false;
    description = "Status Lantern factory run user";
    linger = true;
    packages = [
      pkgs.devenv
      pkgs.git
      pkgs.jq
      pkgs.openssh
      llmAgents.claude-code
      llmAgents.codex
      llmAgents.grok
    ];
  };
  security.sudo.extraRules = [
    {
      users = [ config.oruc.machine.user ];
      runAs = "sl-factory";
      commands = [
        {
          command = "ALL";
          options = [ "NOPASSWD" ];
        }
      ];
    }
  ];
  security.sudo.extraConfig = ''
    Defaults>sl-factory !use_pty
  '';
  boot.kernel.sysctl."dev.tty.legacy_tiocsti" = 0;
  # 100.127.140.73 is observability-1's tailnet address, where
  # signoz.statuslantern.com serves the SigNoz API on 443.
  networking.firewall.extraCommands = ''
    ${slFactoryFenceTeardown}
    ip46tables -N sl-factory-out
    ip46tables -A OUTPUT -m owner --uid-owner sl-factory -j sl-factory-out
    for resolver in 127.0.0.53 127.0.0.54; do
      for protocol in udp tcp; do
        iptables -A sl-factory-out -o lo -d $resolver -p $protocol --dport 53 -j RETURN
      done
    done
    ip46tables -A sl-factory-out -o lo -j REJECT
    iptables -A sl-factory-out -o tailscale0 -d 100.127.140.73 -p tcp --dport 443 -j RETURN
    ip46tables -A sl-factory-out -o tailscale0 -j REJECT
  '';
  networking.firewall.extraStopCommands = slFactoryFenceTeardown;
  environment.systemPackages = [
    (pkgs.writeShellApplication {
      name = "factory-pane";
      text = ''
        worktree=''${1:?usage: factory-pane WORKTREE ACCOUNT COMMAND [ARGS...]}
        exec bash "$worktree/nix/devenv/factory-pane.sh" "$@"
      '';
    })
  ];

  # The box has 62 GiB of RAM (observed on 2026-10-27); the numbers below are
  # guesses for many agents, not measurements.
  boot.kernel.sysctl."vm.swappiness" = 100;
  zramSwap = {
    enable = true;
    algorithm = "zstd";
    memoryPercent = 100;
    memoryMax = 16 * 1024 * 1024 * 1024;
  };
  services.journald.settings.Journal.SystemMaxUse = "2G";
  # /tmp stays on the disk and loses files nobody touched for 7 days, except
  # the sockets of tmux and the X servers, which stay while their owners run.
  # The file sorts before systemd's tmp.conf, so its age wins.
  systemd.tmpfiles.settings.omer-tmp = {
    "/tmp".q = {
      mode = "1777";
      user = "root";
      group = "root";
      age = "7d";
    };
    "/tmp/agents".d = {
      mode = "0755";
      user = config.oruc.machine.user;
      group = config.oruc.machine.user;
      age = "7d";
    };
    "/tmp/tmux-*".x = { };
    "/tmp/.X11-unix".x = { };
    "/tmp/.ICE-unix".x = { };
  };

  home-manager.users.${config.oruc.machine.user}.imports = [ ./home.nix ];

  oruc.tailnetWeb = {
    dnsTokenFile = config.sops.secrets.cloudflare-acme-dns-token.path;
    sites = {
      "openchamber.risoluto.dev" = "127.0.0.1:3000";
      "herdr.risoluto.dev" = "127.0.0.1:7317";
    };
  };

  system.stateVersion = "26.11";
}
