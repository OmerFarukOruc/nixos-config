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

  tailscaleOnlyFires =
    host:
    lib.any (
      a: !a.assertion && lib.hasPrefix "networking.firewall opens a port" a.message
    ) host.config.assertions;
  firewallVariants = {
    tcpPort.networking.firewall.allowedTCPPorts = [ 8080 ];
    tcpPortRange.networking.firewall.allowedTCPPortRanges = [
      {
        from = 8000;
        to = 8010;
      }
    ];
    udpPort.networking.firewall.allowedUDPPorts = [ 5353 ];
    udpPortRange.networking.firewall.allowedUDPPortRanges = [
      {
        from = 9000;
        to = 9010;
      }
    ];
    trustedInterface.networking.firewall.trustedInterfaces = [ "eth0" ];
    interfacePort.networking.firewall.interfaces.eth0.allowedTCPPorts = [ 8080 ];
  };

  hasPackage =
    prefixes: packages:
    lib.any (package: lib.any (prefix: lib.hasPrefix prefix (package.name or "")) prefixes) packages;
  isEfiLimine =
    host: host.config.boot.loader.limine.enable && host.config.boot.loader.efi.canTouchEfiVariables;
  pieces =
    system:
    let
      inherit (system) config;
      home = config.home-manager.users.${config.oruc.machine.user};
    in
    {
      networkManager = config.networking.networkmanager.enable;
      displayManager = config.services.displayManager.enable;
      sddm = config.services.displayManager.sddm.enable;
      plasma = config.services.desktopManager.plasma6.enable;
      niri = config.programs.niri.enable;
      docker = config.virtualisation.docker.enable;
      pipewire = config.services.pipewire.enable;
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
      wallpaper = hasPackage [ "oruc-wallpaper-path" ] home.home.packages;
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

  firewallVariantsNotFailing = lib.attrNames (
    lib.filterAttrs (
      _: module: !tailscaleOnlyFires (system.extendModules { modules = [ module ]; })
    ) firewallVariants
  );

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

  streamed = {
    accepted = validates { features.streamedDesktop = true; };
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
    remoteAccess = !validates { features.remoteAccess = true; };
    biosDeviceWithSystemdBoot = !validates { bootloader = "systemd-boot"; };
  };

  limineHosts = lib.mapAttrs (_: host: {
    inherit (host.config.boot.loader.limine) efiInstallAsRemovable;
    fallbackCopy = host.config.boot.loader.limine.additionalFiles ? "efi/boot/BOOTX64.EFI";
  }) (lib.filterAttrs (_: isEfiLimine) flake.nixosConfigurations);
}
