{ inputs }:
let
  inherit (inputs.nixpkgs) lib;

  # The attribute name is the machine name.
  rawMachines = {
    # Home lab box, half headless.
    nixos-latitude = {
      system = "x86_64-linux";
      kind = "workstation";
      formFactor = "laptop";
      sessions = [
        {
          desktop = "niri";
          shell = "noctalia";
        }
      ];
      launcher = "vicinae";
      theme = {
        scheme = "warm-burnout-dark";
        schemes = [
          "gruvbox-dark-medium"
          "warm-burnout-light"
          "catppuccin-mocha"
        ];
      };
      kernel.profile = "cachyos-latest-lto-x86_64-v3";
      gpu = "intel";
      hasBattery = true;
      features = {
        remoteAccess = true;
        remoteDesktop = true;
        docker = true;
        diskSelfTests = true;
        audioEffects = true;
      };
    };

    # Daily driver.
    nixos-rog = {
      system = "x86_64-linux";
      kind = "workstation";
      formFactor = "laptop";
      sessions = [
        {
          desktop = "plasma";
          shell = "plasma";
        }
        {
          desktop = "niri";
          shell = "noctalia";
        }
        {
          desktop = "niri";
          shell = "dms";
        }
      ];
      launcher = "rofi";
      theme = {
        scheme = "warm-burnout-dark";
        schemes = [
          "gruvbox-dark-medium"
          "warm-burnout-light"
          "catppuccin-mocha"
        ];
        plasmaLook = "glass";
      };
      kernel.profile = "cachyos-latest-lto-zen4";
      bootloader = "limine";
      gpu = "hybrid";
      hasBattery = true;
      features = {
        remoteAccess = true;
        remoteDesktop = false;
        docker = true;
        diskSelfTests = false;
        audioEffects = true;
      };
    };

    # Inventory metadata only. This machine becomes deployable after its real
    # hardware configuration and host-specific policy are available.
    nixos-desktop = {
      system = "x86_64-linux";
      kind = "workstation";
      formFactor = "desktop";
      sessions = [
        {
          desktop = "niri";
          shell = "noctalia";
        }
      ];
      gpu = "unknown";
      hasBattery = false;
      features = {
        remoteAccess = true;
        remoteDesktop = false;
        docker = false;
        diskSelfTests = false;
      };
    };
  };

  machineSchema = import ./schema.nix { inherit inputs lib; };
  validateMachine =
    name: machine:
    (lib.evalModules {
      modules = [
        {
          options.machine = machineSchema.machineOption;
          config.machine = machine // {
            inherit name;
          };
        }
      ];
    }).config.machine;
  machines = lib.mapAttrs validateMachine rawMachines;

  mkMachine =
    { machine, hostModules }:
    lib.nixosSystem {
      inherit (machine) system;
      specialArgs = { inherit inputs; };
      modules = [
        ../nixosModules/default.nix
        { oruc.machine = machine; }
      ]
      ++ hostModules;
    };
in
# Validates the planned machines too, which have no nixosConfiguration yet.
assert builtins.deepSeq machines true;
{
  nixosConfigurations.nixos-latitude = mkMachine {
    machine = machines.nixos-latitude;
    hostModules = [
      ./nixos-latitude/configuration.nix
      ./nixos-latitude/hardware-configuration.nix
    ];
  };

  nixosConfigurations.nixos-rog = mkMachine {
    machine = machines.nixos-rog;
    hostModules = [
      ./nixos-rog/configuration.nix
      ./nixos-rog/hardware-configuration.nix
    ];
  };
}
