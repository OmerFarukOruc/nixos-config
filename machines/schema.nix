{ inputs, lib }:
let
  inherit (lib) mkOption types;
  selectors = import ./selectors.nix;
  sessions = import ./sessions.nix { inherit lib; };
  schemeNames = lib.attrNames (import ./schemes.nix { inherit inputs lib; });

  mkFeature =
    description:
    mkOption {
      type = types.bool;
      default = false;
      inherit description;
    };
  mkIdleSeconds =
    default: description:
    mkOption {
      type = types.nullOr types.ints.positive;
      inherit default description;
    };
  # Idle screen timeouts for one power state. The screen never locks and the
  # machine never suspends on idle.
  mkIdle = dim: screenOff: power: {
    dimSeconds = mkIdleSeconds dim "Seconds of inactivity ${power} before the screen dims, or null to never dim.";
    screenOffSeconds = mkIdleSeconds screenOff "Seconds of inactivity ${power} before the screen turns off, or null to keep it on.";
  };
  machineOptions = {
    name = mkOption {
      type = types.strMatching "[a-z0-9][a-z0-9-]*";
      description = "Stable name of this machine in the flake inventory.";
    };

    system = mkOption {
      type = types.str;
      description = "Nix system used to construct this machine.";
    };

    kind = mkOption {
      type = types.enum [
        "workstation"
        "server"
      ];
      description = "Broad role used by shared modules.";
    };

    formFactor = mkOption {
      type = types.enum [
        "laptop"
        "desktop"
      ];
      description = "Physical machine class, independent of its hardware file.";
    };

    sessions = mkOption {
      type = types.listOf (
        types.submodule {
          options = {
            desktop = mkOption {
              type = types.enum selectors.desktopNames;
              description = "Compositor or desktop environment that this login session starts.";
            };
            shell = mkOption {
              type = types.enum selectors.shellNames;
              description = "Desktop shell of this session: bar, notifications, wallpaper, and shell binds.";
            };
          };
        }
      );
      default = [ ];
      description = "Login sessions offered by the display manager. The first one is the default session. An empty list means no desktop.";
    };

    bootloader = mkOption {
      type = types.enum [
        "systemd-boot"
        "limine"
      ];
      default = "systemd-boot";
      description = "UEFI boot loader that installs this machine's generations. Limine can also install a BIOS stage (biosDevice).";
    };

    biosDevice = mkOption {
      type = types.nullOr (types.strMatching "/dev/.+");
      default = null;
      example = "/dev/vda";
      description = "Disk on which Limine also installs its BIOS stage, for a machine that boots through BIOS or either firmware. The EFI loader is always installed, so the machine needs an EFI system partition. A machine that boots through BIOS also sets boot.loader.efi.canTouchEfiVariables = false in its own files, because its firmware keeps no boot entries. With null Limine installs the EFI loader only.";
    };

    launcher = mkOption {
      type = types.enum selectors.launcherNames;
      default = "rofi";
      description = "Application launcher selected by this machine.";
    };

    theme.scheme = mkOption {
      type = types.enum schemeNames;
      default = "gruvbox-dark-medium";
      description = "Base16 scheme selected by this machine, named as in the pinned schemes input or assets/schemes. The login screen, the boot menu, the console and niri always use it, and Home Manager uses it until `theme` selects another one.";
    };

    theme.schemes = mkOption {
      type = types.listOf (types.enum schemeNames);
      default = [ ];
      description = "Other Base16 schemes that `theme` switches Home Manager to without a rebuild. Each one adds a Home Manager build per Plasma look to every deploy.";
    };

    theme.plasmaLook = mkOption {
      type = types.nullOr (types.enum selectors.plasmaLookNames);
      default = null;
      description = "Plasma look that a login uses until `plasma-look` selects another one. A machine with no Plasma session leaves it null.";
    };

    kernel.profile = mkOption {
      type = types.enum selectors.kernelNames;
      default = "cachyos-latest-lto-x86_64-v3";
      description = "Kernel profile selected by this machine.";
    };

    gpu = mkOption {
      type = types.enum [
        "unknown"
        "intel"
        "amd"
        "nvidia"
        "hybrid"
      ];
      description = ''
        GPU class. intel and amd turn on nixosModules/intel-graphics.nix or
        amd-graphics.nix. hybrid is a Radeon with an NVIDIA card, which the
        host's own files set up. unknown selects no GPU module. The Home
        Manager profiles pick GPU tools by it.
      '';
    };

    hasBattery = mkOption {
      type = types.bool;
      description = "Whether the machine has a battery.";
    };

    deployed = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Whether the machine runs this configuration. A machine that sets false
        runs another system, and scripts/affected-hosts.sh prints it as
        not-deployed.
      '';
    };

    deployLogin = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "root";
      description = ''
        The user that deploy.sh and scripts/affected-hosts.sh log in as over
        SSH. null keeps the login of the host's SSH alias. A server sets root,
        because its user's sudo asks for a password that a deploy cannot type.
        The release records of a deploy are in this user's home.
      '';
    };

    autoLogin = mkOption {
      type = types.bool;
      default = false;
      description = "Whether the display manager logs oruc in at boot, into a locked Plasma session.";
    };

    # Every desktop of the machine reads these, so its sessions behave alike.
    idle = {
      battery = mkIdle 120 300 "on battery power";
      ac = mkIdle null null "on AC power";
    };

    touchpad = {
      tapToClick = mkOption {
        type = types.bool;
        default = true;
        description = "Whether a tap on the touchpad clicks.";
      };
      naturalScroll = mkOption {
        type = types.bool;
        default = true;
        description = "Whether touchpad scrolling moves the content with the fingers.";
      };
    };

    features = mkOption {
      default = { };
      type = types.submodule {
        options = {
          remoteAccess = mkFeature "Enable remote shell access.";
          remoteDesktop = mkFeature "Host a remote desktop with Sunshine.";
          docker = mkFeature "Enable the Docker daemon and client tooling.";
          diskSelfTests = mkFeature "Schedule the smartd short and long disk self-tests.";
          audioEffects = mkFeature "Run EasyEffects as a user service in graphical sessions.";
          alwaysOn = mkFeature "Never sleep, and reboot after a panic or a hang (nixosModules/always-on.nix). It does not mean the machine stays powered on.";
          boxBrowser = mkFeature "Run a signed-in Chromium on a VNC display for coding agents, with the box-browser command (nixosModules/box-browser.nix).";
        };
      };
      description = "Explicit feature switches consumed by self-gating modules.";
    };
  };

  validate =
    machine:
    let
      desktops = sessions.desktops machine;
    in
    assert lib.assertMsg (
      machine.kind == "workstation" || desktops == [ ]
    ) "Only workstation machines may offer a desktop session.";
    assert lib.assertMsg (
      machine.kind == "workstation" || machine.theme.schemes == [ ]
    ) "Only workstation machines may list theme.schemes, because only they get the theme command.";
    # nixosModules/connectivity.nix, which sets up SSH and sudo for this feature,
    # is workstation-only.
    assert lib.assertMsg (
      machine.kind == "workstation" || !machine.features.remoteAccess
    ) "Only workstation machines may set features.remoteAccess.";
    assert lib.assertMsg (
      machine.biosDevice == null || machine.bootloader == "limine"
    ) "Only the limine boot loader installs a BIOS stage, so ${machine.name} cannot set biosDevice.";
    assert lib.assertMsg (
      (!machine.features.remoteDesktop) || machine.features.remoteAccess
    ) "The remoteDesktop feature requires remoteAccess.";
    assert lib.assertMsg (
      lib.length (lib.unique machine.sessions) == lib.length machine.sessions
    ) "Each session must pair a different desktop and shell.";
    # nixosModules/desktop.nix makes one login entry per shell only for niri.
    assert lib.assertMsg (lib.all (
      desktop: desktop == "niri" || !sessions.hasSeveralShells machine desktop
    ) desktops) "Only niri may offer more than one shell.";
    assert lib.assertMsg (lib.all (
      desktop: builtins.elem desktop selectors.launcherSpecs.${machine.launcher}.desktops
    ) desktops) "Launcher ${machine.launcher} is not supported by every desktop of this machine.";
    assert lib.assertMsg (lib.all (
      session: builtins.elem session.desktop selectors.shellSpecs.${session.shell}.desktops
    ) machine.sessions) "A session selects a shell that its desktop does not support.";
    assert lib.assertMsg (
      sessions.hasDesktop machine "plasma" -> machine.theme.plasmaLook != null
    ) "${machine.name} has a Plasma session and no theme.plasmaLook.";
    # Only Plasma locks the session that autologin starts.
    assert lib.assertMsg (
      machine.autoLogin -> desktops == [ "plasma" ]
    ) "${machine.name} sets autoLogin, which needs Plasma as its only desktop.";
    assert lib.assertMsg (
      sessions.hasDesktop machine "plasma" || machine.theme.plasmaLook == null
    ) "${machine.name} sets theme.plasmaLook and has no Plasma session.";
    assert lib.all
      (
        power:
        let
          idle = machine.idle.${power};
        in
        lib.assertMsg (
          idle.dimSeconds == null || idle.screenOffSeconds == null || idle.screenOffSeconds > idle.dimSeconds
        ) "${machine.name} ${power} screen-off must be later than dim."
      )
      [
        "battery"
        "ac"
      ];
    machine;
in
{
  machineOption = mkOption {
    type = types.submodule { options = machineOptions; };
    apply = validate;
    description = "Validated machine inventory record.";
  };
}
