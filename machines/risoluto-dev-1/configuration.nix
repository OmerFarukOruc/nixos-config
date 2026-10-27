# Omer's dev box: a netcup KVM guest that runs his coding agents. Role and boot
# loader: machines/inventory.nix. Access: nixosModules/server-access.nix.
{
  config,
  inputs,
  lib,
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
  ];

  # The Limine install runs from a BIOS boot too, where the firmware keeps no
  # boot entries to write (nixosModules/bootloader.nix).
  boot.loader.efi.canTouchEfiVariables = false;

  services.qemuGuest.enable = true;

  sops = {
    defaultSopsFile = ../../secrets/risoluto-dev-1.yaml;
    age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
    secrets = {
      oruc-password-hash.neededForUsers = true;
      root-password-hash.neededForUsers = true;
      network-ipv4-address = { };
      network-ipv4-gateway = { };
      network-ipv6-address = { };
      network-dns-1 = { };
      network-dns-2 = { };
      network-dns-3 = { };
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

  networking = {
    useDHCP = false;
    useNetworkd = true;
  };
  services.resolved.enable = true;
  environment.etc."systemd/network/10-public.network".source =
    config.sops.templates."10-public.network".path;

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
  systemd.slices.user.sliceConfig.ManagedOOMSwap = lib.mkForce "auto";
  boot.kernel.sysctl."vm.swappiness" = lib.mkForce 100;
  zramSwap = {
    enable = true;
    algorithm = "zstd";
    memoryPercent = 100;
    memoryMax = 16 * 1024 * 1024 * 1024;
  };
  services.journald.settings.Journal.SystemMaxUse = lib.mkForce "2G";
  # /tmp stays on the disk and loses files nobody touched for 7 days. The file
  # sorts before systemd's tmp.conf, so its age wins.
  systemd.tmpfiles.settings.oruc-tmp."/tmp".q = {
    mode = "1777";
    user = "root";
    group = "root";
    age = "7d";
  };

  system.stateVersion = "26.11";
}
