{ lib, pkgs, ... }:
{
  config = {
    nixpkgs.config.allowUnfree = true;
    nixpkgs.overlays = [ (import ../overlays/deskflow.nix) ];

    # cache.numtide.com holds the builds of the coding agents (llm-agents.nix) that
    # home-manager/modules/applications.nix installs on every host.
    nix.settings = {
      extra-substituters = [ "https://cache.numtide.com" ];
      extra-trusted-public-keys = [ "niks3.numtide.com-1:DTx8wZduET09hRmMtKdQDxNNthLQETkc/yaX7M4qK0g=" ];
    };

    # Lets git and gh reach GitHub over SSH without a first-use prompt. The
    # fingerprint SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU matches
    # https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/githubs-ssh-key-fingerprints
    programs.ssh.knownHosts."github.com".publicKey =
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl";

    time.timeZone = "Europe/Istanbul";
    i18n = {
      defaultLocale = "en_US.UTF-8";
      # English interface with Turkish formats. Numbers, sorting, character
      # types, and messages stay en_US.
      extraLocaleSettings = {
        LC_ADDRESS = "tr_TR.UTF-8";
        LC_MEASUREMENT = "tr_TR.UTF-8";
        LC_MONETARY = "tr_TR.UTF-8";
        LC_NAME = "tr_TR.UTF-8";
        LC_PAPER = "tr_TR.UTF-8";
        LC_TELEPHONE = "tr_TR.UTF-8";
        LC_TIME = "tr_TR.UTF-8";
      };
    };
    console.keyMap = "trq";
    # The SDDM greeter and niri, through /etc/niri/host.kdl, read their layout
    # from here.
    services.xserver.xkb.layout = "tr";

    nix = {
      settings = {
        experimental-features = [
          "nix-command"
          "flakes"
        ];
        trusted-users = [
          "root"
          "oruc"
        ];
        # Move on to the next substituter, or build locally, when a cache does
        # not answer within 5 s.
        connect-timeout = 5;
        # A GC keeps the build inputs of every live derivation, so the next
        # rebuild does not download or rebuild them again. keep-derivations,
        # its pair, is on by default.
        keep-outputs = true;
      };
      # angrr decides which system generations go, so the GC deletes none itself.
      gc = {
        automatic = true;
        dates = "daily";
      };
      optimise = {
        automatic = true;
        dates = [ "weekly" ];
      };
    };

    # Runs before each nix-gc; docs/recovery.md states which generations it keeps.
    services.angrr = {
      enable = true;
      settings.profile-policies.system = {
        profile-paths = [ "/nix/var/nix/profiles/system" ];
        keep-latest-n = 5;
        keep-current-system = true;
        keep-booted-system = true;
        # angrr counts each day back from its run, not by calendar day.
        keep-n-per-bucket = [
          {
            bucket-window = "1 day";
            bucket-amount = 7;
          }
        ];
      };
    };

    services.journald.settings.Journal = {
      MaxRetentionSec = "7day";
      SystemMaxUse = "1G";
    };

    # A stuck service delays a shutdown 30 s instead of 90 s.
    systemd.settings.Manager.DefaultTimeoutStopSec = "30s";

    # Crash dumps take at most 1 GiB and go after 3 days. systemd's own
    # tmpfiles.d/systemd.conf, which NixOS ships, keeps them 2 weeks. The file
    # of this rule, coredump.conf, sorts first, so its age wins.
    systemd.coredump.settings.Coredump.MaxUse = "1G";
    systemd.tmpfiles.settings.coredump."/var/lib/systemd/coredump".d = {
      mode = "0755";
      user = "root";
      group = "root";
      age = "3d";
    };

    boot.initrd.compressor = "zstd";
    boot.initrd.compressorArgs = [ "-19" ];

    # Kernel modules no one here uses, with a history of local privilege
    # escalations: IPsec ESP, RxRPC, and RDS. An IPsec VPN needs esp4 and
    # esp6 back.
    boot.extraModprobeConfig =
      lib.concatMapStrings
        (module: ''
          blacklist ${module}
          install ${module} ${pkgs.coreutils}/bin/true
        '')
        [
          "esp4"
          "esp6"
          "rxrpc"
          "rds"
          "rds_tcp"
        ];

    # A phone's carrier sees tethered packets with the phone's own TTL: 65
    # here, 64 after the phone's hop. Containers get a network namespace of
    # their own, which starts at 64.
    boot.kernel.sysctl = {
      "net.ipv4.ip_default_ttl" = 65;
      "net.ipv6.conf.all.hop_limit" = 65;
      "net.ipv6.conf.default.hop_limit" = 65;
      # Interfaces that exist before the sysctls load.
      "net.ipv6.conf.*.hop_limit" = 65;
    };

    # Prebuilt Linux binaries find their loader and common libraries.
    programs.nix-ld.enable = true;

    security.sudo.execWheelOnly = true;

    # Wi-Fi and other cards, such as the MT7925 in nixos-rog, need linux-firmware.
    hardware.enableAllFirmware = true;
    services.fwupd.enable = true;
    # Every switch writes /etc/localtime again, and systemd then picks a new
    # random delay for calendar timers. The hourly fwupd-refresh timer, with up
    # to an hour of delay, so fired during most switches. It ran the old
    # fwupdmgr against the new daemon after an fwupd update, which fails with
    # "Unsupported daemon version" and fails the switch. A fixed delay keeps
    # the next run where it was.
    systemd.timers.fwupd-refresh.timerConfig.FixedRandomDelay = true;

    environment.variables.DO_NOT_TRACK = "1";

    users.users.oruc = {
      isNormalUser = true;
      extraGroups = [ "wheel" ];
      shell = pkgs.zsh;
      openssh.authorizedKeys.keys = [
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMV6Kg6JIDEOFDbA5ezTsHnxFq2fXzB75x0+tybHlB/h omer-all-devices"
      ];
    };
    programs.zsh.enable = true;
    # Home Manager's nix-index answers unknown commands.
    programs.command-not-found.enable = false;
  };
}
