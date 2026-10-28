{
  config,
  lib,
  pkgs,
  sessions,
  ...
}:
let
  cfg = config.oruc.machine;
in
{
  config = {
    nixpkgs.config.allowUnfree = true;
    nixpkgs.overlays = [ (import ../overlays/deskflow.nix) ];

    nix.settings = {
      extra-substituters = [ "https://cache.numtide.com" ];
      extra-trusted-public-keys = [ "niks3.numtide.com-1:DTx8wZduET09hRmMtKdQDxNNthLQETkc/yaX7M4qK0g=" ];
    };

    programs.ssh.knownHosts = {
      # Lets git and gh reach GitHub over SSH without a first-use prompt. The
      # fingerprint SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU matches
      # https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/githubs-ssh-key-fingerprints
      "github.com".publicKey =
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl";

      nixos-desktop.publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHBSVaj7MrTnp/7Fg7zAzPJgMeeqETySFH6MtLX6GgGR";
      nixos-latitude.publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIO92VnaHsupV1yTYiGYal+7LgHABYQfE0ljjODnw2uUS";
      nixos-rog.publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIM7Dy/fKeDEATVy33fCAUdsnXmRN6eSjPAxf63xBU+id";
    };

    time.timeZone = "Europe/Istanbul";
    i18n = {
      defaultLocale = "en_US.UTF-8";
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
    services.xserver.xkb.layout = lib.mkIf (sessions.hasGraphicalUser cfg) "tr";

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
        connect-timeout = 5;
        keep-outputs = true;
      };
      gc = {
        automatic = true;
        dates = "daily";
      };
      optimise = {
        automatic = true;
        dates = [ "weekly" ];
      };
    };

    services.angrr = {
      enable = true;
      settings.profile-policies.system = {
        profile-paths = [ "/nix/var/nix/profiles/system" ];
        keep-latest-n = 5;
        keep-current-system = true;
        keep-booted-system = true;
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
      SystemMaxUse = lib.mkDefault "1G";
    };

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
    # their own, which starts at 64. Only a workstation is tethered.
    boot.kernel.sysctl = lib.mkIf (cfg.kind == "workstation") {
      "net.ipv4.ip_default_ttl" = 65;
      "net.ipv6.conf.all.hop_limit" = 65;
      "net.ipv6.conf.default.hop_limit" = 65;
      "net.ipv6.conf.*.hop_limit" = 65;
    };

    programs.nix-ld.enable = true;

    environment.etc =
      lib.mkIf
        (builtins.elem cfg.name [
          "nixos-desktop"
          "nixos-rog"
        ])
        {
          "ssl/cert.pem".source = config.security.pki.caBundle;
        };

    security.sudo.execWheelOnly = true;

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
    programs.command-not-found.enable = false;
  };
}
