{
  config,
  inputs,
  ...
}:
let
  secret = name: config.sops.placeholder.${name};
in
{
  imports = [
    inputs.disko.nixosModules.disko
    inputs.sops-nix.nixosModules.sops
    ./disk.nix
    ./services.nix
    ../../nixosModules/agent-runtime.nix
    ../../nixosModules/envfs.nix
    ../../nixosModules/rootless-containers.nix
    ../../nixosModules/tailnet-web.nix
  ];

  boot.loader.efi.canTouchEfiVariables = false;

  services.qemuGuest.enable = true;

  # smartd failed to start in the boot test (smartd.service: Failed with result
  # 'exit-code'), whose virtio disk is the kind this host has. A unit that fails
  # during a switch makes the switch exit 4, which deploy.sh rolls back.
  # nixosModules/monitoring.nix enables smartd unless a host says otherwise.
  services.smartd.enable = false;

  oruc.deploy = {
    self = {
      enable = true;
      githubTokenFile = config.sops.secrets.github-update-token.path;
    };
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
      github-update-token.sopsFile = ../../secrets/devbox-github.yaml;
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
    filesystemMounts = [ "/tmp" ];
    journalUnits = [
      "caddy.service"
      "acme-*.service"
      "xrdp.service"
      "xrdp-sesman.service"
    ];
    journalUserUnits = [ "docker.service" ];
  };

  networking = {
    useDHCP = false;
    useNetworkd = true;
  };
  services.resolved.enable = true;
  environment.etc."systemd/network/10-public.network".source =
    config.sops.templates."10-public.network".path;

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
