# A server record: kind = "server", Limine with its BIOS stage beside the EFI
# loader, and no login sessions, without the files of any host (risoluto-dev-1
# adds its own). Each value of `workstation` says whether a piece that only a
# workstation or a desktop needs came in, so all must be false. `access` shows
# the Tailscale and SSH setup of a server, and `boot` shows that the boot loader
# follows the record. `accepted` and `rejected` run the record through the
# schema of machines/schema.nix: the record itself must pass, and each change
# that the schema forbids must fail.
#
# `streamed` evaluates the same record with features.streamedDesktop: of the
# workstation pieces only the fonts, browser and keyboard layout of a
# graphical user come in, and xrdp runs with no X server or display manager at
# boot.
#
# Takes the root flake; returns { drvPath, workstation, access, boot, accepted,
# rejected, streamed, limineHosts }. limineHosts holds the Limine settings of each host
# that installs Limine and can write EFI variables, which keeps the fallback
# copy.
flake:
let
  inherit (flake) inputs;
  inherit (inputs.nixpkgs) lib;
  mkSystem =
    machine:
    lib.nixosSystem {
      specialArgs = { inherit inputs; };
      modules = [
        ../nixosModules/default.nix
        {
          oruc.machine = machine;
          nixpkgs.hostPlatform = "x86_64-linux";
          boot.loader.efi.canTouchEfiVariables = false;
          fileSystems = {
            "/" = {
              device = "/dev/vda2";
              fsType = "ext4";
            };
            "/boot" = {
              device = "/dev/vda1";
              fsType = "vfat";
            };
          };
          system.stateVersion = "26.11";
        }
      ];
    };
  system = mkSystem record;
  inherit (system) config;
  streamedSystem = mkSystem (lib.recursiveUpdate record { features.streamedDesktop = true; });

  # The record as machines/inventory.nix validates it, with changes merged in.
  machineSchema = import ../machines/schema.nix { inherit inputs lib; };
  record = {
    name = "server-record";
    system = "x86_64-linux";
    kind = "server";
    formFactor = "desktop";
    gpu = "unknown";
    hasBattery = false;
    bootloader = "limine";
    biosDevice = "/dev/vda";
  };
  validates =
    change:
    (builtins.tryEval (
      builtins.deepSeq
        (lib.evalModules {
          modules = [
            {
              options.machine = machineSchema.machineOption;
              config.machine = lib.recursiveUpdate record change;
            }
          ];
        }).config.machine
        true
    )).success;

  hasPackage =
    prefixes: packages:
    lib.any (package: lib.any (prefix: lib.hasPrefix prefix (package.name or "")) prefixes) packages;
  # A host that installs Limine and can write EFI variables keeps the copy of
  # its EFI binary at the firmware fallback path.
  isEfiLimine =
    host: host.config.boot.loader.limine.enable && host.config.boot.loader.efi.canTouchEfiVariables;
  enabledFiles = files: lib.attrNames (lib.filterAttrs (_: file: file.enable) files);
  # Each value says whether a piece that only a workstation or a desktop needs
  # came into this system.
  pieces =
    system:
    let
      inherit (system) config;
      home = config.home-manager.users.oruc;
    in
    {
      networkManager = config.networking.networkmanager.enable;
      displayManager = config.services.displayManager.enable;
      sddm = config.services.displayManager.sddm.enable;
      plasma = config.services.desktopManager.plasma6.enable;
      niri = config.programs.niri.enable;
      docker = config.virtualisation.docker.enable;
      pipewire = config.services.pipewire.enable;
      # The command of nixosModules/hm-variants.nix.
      themeCommand = hasPackage [ "theme" ] config.environment.systemPackages;
      ghostty = home.programs.ghostty.enable;
      vscode = home.programs.vscode.enable;
      mimeApps = home.xdg.mimeApps.enable;
      fontconfig = home.fonts.fontconfig.enable;
      desktopPackages = hasPackage [
        "brave"
        "firefox"
        "google-chrome"
        "nerd-fonts"
        "noto-fonts"
        "pandoc-md-viewer"
        "sourcegit"
        "vscode"
      ] home.home.packages;
      wallpaper = lib.any (lib.hasPrefix "backgrounds/") (enabledFiles home.xdg.dataFile);
      xkbLayout = config.services.xserver.xkb.layout != "us";
      tetherTtl = config.boot.kernel.sysctl ? "net.ipv4.ip_default_ttl";
      browserCertificates = home.home.activation ? nssDatabase;
      browserVariable = home.home.sessionVariables ? BROWSER;
      failurePopup = config.systemd.services ? "notify-failure@";
      systembusNotify = config.systemd.user.services ? systembus-notify;
      ghosttyScope = config.systemd.user.units ? "app-ghostty-surface-transient-.scope";
    };
in
{
  drvPath = config.system.build.toplevel.drvPath;

  workstation = pieces system;

  # What nixosModules/server-access.nix and ssh.nix give a server.
  access = {
    tailscale = config.services.tailscale.enable;
    tailscaleSsh = lib.elem "--ssh" config.services.tailscale.extraSetFlags;
    openssh = config.services.openssh.enable;
    sshOpenFirewall = config.services.openssh.openFirewall;
    sshPorts = config.services.openssh.ports;
    sshAuthentication = config.services.openssh.settings.AuthenticationMethods;
    sshListenAddresses = map (
      a: "${a.addr}:${toString a.port}"
    ) config.services.openssh.listenAddresses;
    udpPorts = config.networking.firewall.allowedUDPPorts;
    tailscalePort = config.services.tailscale.port;
  };

  boot = {
    inherit (config.boot.loader.limine)
      enable
      efiSupport
      biosSupport
      biosDevice
      efiInstallAsRemovable
      additionalFiles
      ;
    inherit (config.boot.loader.efi) canTouchEfiVariables;
  };

  accepted = validates { };

  # The same record with a streamed desktop: the schema accepts it, and the
  # system gets the desktop and its graphical user's pieces and no more.
  streamed = {
    accepted = validates { features.streamedDesktop = true; };
    # Without it the rejection of streamedDesktopOnWorkstation proves nothing,
    # because the schema might reject a workstation of this record for another
    # reason.
    workstationAccepted = validates { kind = "workstation"; };
    workstation = pieces streamedSystem;
    desktop = {
      xserver = streamedSystem.config.services.xserver.enable;
      xrdp = streamedSystem.config.services.xrdp.enable;
      screensaver = streamedSystem.config.services.xserver.desktopManager.xfce.enableScreensaver;
      keyboardLayout = streamedSystem.config.services.xserver.xkb.layout;
    };
  };

  rejected = {
    streamedDesktopOnWorkstation =
      !validates {
        kind = "workstation";
        features.streamedDesktop = true;
      };
    themeSchemes = !validates { theme.schemes = [ "catppuccin-mocha" ]; };
    remoteAccess = !validates { features.remoteAccess = true; };
    biosDeviceWithSystemdBoot = !validates { bootloader = "systemd-boot"; };
  };

  limineHosts = lib.mapAttrs (_: host: {
    inherit (host.config.boot.loader.limine) efiInstallAsRemovable;
    fallbackCopy = host.config.boot.loader.limine.additionalFiles ? "efi/boot/BOOTX64.EFI";
  }) (lib.filterAttrs (_: isEfiLimine) flake.nixosConfigurations);
}
