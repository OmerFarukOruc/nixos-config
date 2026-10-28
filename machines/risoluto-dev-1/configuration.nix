# Omer's dev box: a netcup KVM guest that runs his coding agents. Role and boot
# loader: machines/inventory.nix. Access: nixosModules/server-access.nix.
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

  # The Limine install runs from a BIOS boot too, where the firmware keeps no
  # boot entries to write (nixosModules/bootloader.nix).
  boot.loader.efi.canTouchEfiVariables = false;

  services.qemuGuest.enable = true;

  # smartd failed to start in the boot test (smartd.service: Failed with result
  # 'exit-code'), whose virtio disk is the kind this host has. A unit that fails
  # during a switch makes the switch exit 4, which deploy.sh rolls back.
  # nixosModules/monitoring.nix enables smartd unless a host says otherwise.
  services.smartd.enable = false;

  # The box keeps itself on main (docs/deploy.md, Self-deploy of a server).
  oruc.deploy = {
    self = {
      enable = true;
      githubTokenFile = config.sops.secrets.github-update-token.path;
    };
    # Long-running agents, which a switch may restart. The user services that a
    # timer or socket starts are left out already.
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
    defaultSopsFile = ../../secrets/risoluto-dev-1.yaml;
    secrets = {
      oruc-password-hash.neededForUsers = true;
      root-password-hash.neededForUsers = true;
      network-ipv4-address = { };
      network-ipv4-gateway = { };
      network-ipv6-address = { };
      network-dns-1 = { };
      network-dns-2 = { };
      network-dns-3 = { };
      # Its own file, because the recipients of the main one need the shared
      # key's passphrase to add a value.
      cloudflare-acme-dns-token.sopsFile = ../../secrets/risoluto-dev-1-acme.yaml;
      # The deploy unit's token (docs/risoluto-dev-1.md, Rotate the box's
      # token) has its own file.
      github-update-token.sopsFile = ../../secrets/risoluto-dev-1-github.yaml;
    };
    # The public address stays out of this repository, so networkd reads it
    # from a file that sops-nix renders when the system activates. On a boot
    # activation runs before systemd starts, and a switch that changes the file
    # restarts networkd.
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
    # oruc's rootless Docker daemon (nixosModules/rootless-containers.nix).
    journalUserUnits = [ "docker.service" ];
  };

  networking = {
    useDHCP = false;
    useNetworkd = true;
  };
  services.resolved.enable = true;
  environment.etc."systemd/network/10-public.network".source =
    config.sops.templates."10-public.network".path;

  # A password hash that changes in the sops file applies at the next
  # activation, and users that this configuration does not declare go away.
  users.mutableUsers = false;
  users.groups.oruc.gid = 1003;
  users.users.oruc = {
    uid = 1003;
    group = "oruc";
    # Rootless containers map their users into this range.
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
    # oruc's user services keep running without a login.
    linger = true;
    hashedPasswordFile = config.sops.secrets.oruc-password-hash.path;
  };
  # The netcup console logs in as root.
  users.users.root.hashedPasswordFile = config.sops.secrets.root-password-hash.path;

  # Agent sessions run in the user slice, so systemd-oomd must not kill it for
  # swap use (nixosModules/memory.nix). The box has 62 GiB of RAM (observed on
  # 2026-10-27); the numbers below are guesses for many agents, not measurements.
  systemd.slices.user.sliceConfig.ManagedOOMSwap = "auto";
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
  systemd.tmpfiles.settings.oruc-tmp = {
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

  # oruc's Home Manager layer: the hourly config sync of the dotfiles checkout.
  home-manager.users.oruc.imports = [ ./home.nix ];

  # The web names of oruc's services. Each has a public, DNS-only A record to
  # the host's tailnet address, so it answers only on the tailnet. The
  # services listen on loopback: OpenChamber, then the herdr web UIs of the
  # default session and of the bots' fleet session.
  oruc.tailnetWeb = {
    dnsTokenFile = config.sops.secrets.cloudflare-acme-dns-token.path;
    sites = {
      "openchamber.risoluto.dev" = "127.0.0.1:3000";
      "herdr.risoluto.dev" = "127.0.0.1:7317";
      "herdr-fleet.risoluto.dev" = "127.0.0.1:7318";
    };
  };

  system.stateVersion = "26.11";
}
