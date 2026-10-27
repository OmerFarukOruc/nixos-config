# A server record: kind = "server", Limine with its BIOS stage beside the EFI
# loader, and no login sessions. No host is a server yet, so no other check
# evaluates this shape. Each value of `workstation` says whether a piece that
# only a workstation or a desktop needs came in, so all must be false, and
# `boot` shows that the boot loader follows the record.
#
# Takes the root flake; returns { drvPath, workstation, boot, rogBoot }. rogBoot
# is the boot loader of a host that can write EFI variables, which keeps the
# fallback copy.
flake:
let
  inherit (flake) inputs;
  inherit (inputs.nixpkgs) lib;
  system = lib.nixosSystem {
    specialArgs = { inherit inputs; };
    modules = [
      ../nixosModules/default.nix
      {
        oruc.machine = {
          name = "server-record";
          system = "x86_64-linux";
          kind = "server";
          formFactor = "desktop";
          gpu = "unknown";
          hasBattery = false;
          bootloader = "limine";
          biosDevice = "/dev/vda";
        };
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
  inherit (system) config;
  home = config.home-manager.users.oruc;

  hasPackage =
    prefixes: packages:
    lib.any (package: lib.any (prefix: lib.hasPrefix prefix (package.name or "")) prefixes) packages;
  enabledFiles = files: lib.attrNames (lib.filterAttrs (_: file: file.enable) files);
in
{
  drvPath = config.system.build.toplevel.drvPath;

  workstation = {
    networkManager = config.networking.networkmanager.enable;
    tailscale = config.services.tailscale.enable;
    openssh = config.services.openssh.enable;
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

  boot = {
    inherit (config.boot.loader.limine)
      enable
      efiSupport
      biosSupport
      biosDevice
      efiInstallAsRemovable
      extraInstallCommands
      ;
    inherit (config.boot.loader.efi) canTouchEfiVariables;
  };

  rogBoot = {
    inherit (flake.nixosConfigurations.nixos-rog.config.boot.loader.limine) efiInstallAsRemovable;
    fallbackCopy =
      flake.nixosConfigurations.nixos-rog.config.boot.loader.limine.extraInstallCommands != "";
  };
}
