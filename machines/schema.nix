{ inputs, lib }:
let
  inherit (lib) mkOption types;
  selectors = import ./selectors.nix;
  sessions = import ./sessions.nix { inherit lib; };
  schemeNames = import ./schemes.nix { inherit inputs lib; };

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
              type = types.enum [
                "niri"
                "plasma"
              ];
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
      description = "UEFI boot loader that installs this machine's generations.";
    };

    launcher = mkOption {
      type = types.enum selectors.launcherNames;
      default = "rofi";
      description = "Application launcher selected by this machine.";
    };

    theme.scheme = mkOption {
      type = types.enum schemeNames;
      default = "gruvbox-dark-medium";
      description = "Base16 scheme selected by this machine, named as in the pinned schemes input.";
    };

    theme.plasmaLook = mkOption {
      type = types.enum selectors.plasmaLookNames;
      default = "glass";
      description = "Plasma look that a login uses until `plasma-look` selects another one.";
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
      description = "GPU class consumed by optional hardware modules.";
    };

    hasBattery = mkOption {
      type = types.bool;
      description = "Whether the machine has a battery.";
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
          remoteDesktop = mkFeature "Host a remote desktop with Sunshine and install the Remmina client.";
          docker = mkFeature "Enable the Docker daemon and client tooling.";
          diskSelfTests = mkFeature "Schedule the smartd short and long disk self-tests.";
          audioEffects = mkFeature "Run EasyEffects as a user service in graphical sessions.";
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
    machine;
in
{
  machineOption = mkOption {
    type = types.submodule { options = machineOptions; };
    apply = validate;
    description = "Validated machine inventory record.";
  };
}
