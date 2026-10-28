{ inputs }:
let
  inherit (inputs.nixpkgs) lib;

  rawMachines = {
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
        docker = true;
        diskSelfTests = true;
        audioEffects = true;
        alwaysOn = true;
      };
    };

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
        remoteDesktop = true;
        docker = true;
        diskSelfTests = false;
        audioEffects = true;
      };
    };

    # Home desktop and the Deskflow server. It can be off or booted into
    # Windows, so nothing may count on it being up. features.alwaysOn below
    # only keeps it awake while it runs.
    nixos-desktop = {
      system = "x86_64-linux";
      kind = "workstation";
      formFactor = "desktop";
      sessions = [
        {
          desktop = "plasma";
          shell = "plasma";
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
      gpu = "amd";
      hasBattery = false;
      autoLogin = true;
      features = {
        remoteAccess = true;
        remoteDesktop = true;
        docker = true;
        diskSelfTests = true;
        alwaysOn = true;
      };
    };

    risoluto-dev-1 = {
      system = "x86_64-linux";
      kind = "server";
      formFactor = "desktop";
      kernel.profile = "nixos";
      bootloader = "limine";
      biosDevice = "/dev/vda";
      gpu = "unknown";
      hasBattery = false;
      deployLogin = "root";
      features = {
        boxBrowser = true;
        streamedDesktop = true;
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
assert builtins.deepSeq machines true;
{
  nixosConfigurations.nixos-latitude = mkMachine {
    machine = machines.nixos-latitude;
    hostModules = [
      ./nixos-latitude/configuration.nix
      ./nixos-latitude/hardware-configuration.nix
    ];
  };

  nixosConfigurations.nixos-desktop = mkMachine {
    machine = machines.nixos-desktop;
    hostModules = [
      ./nixos-desktop/configuration.nix
      ./nixos-desktop/hardware-configuration.nix
    ];
  };

  nixosConfigurations.nixos-rog = mkMachine {
    machine = machines.nixos-rog;
    hostModules = [
      ./nixos-rog/configuration.nix
      ./nixos-rog/hardware-configuration.nix
    ];
  };

  nixosConfigurations.risoluto-dev-1 = mkMachine {
    machine = machines.risoluto-dev-1;
    hostModules = [
      ./risoluto-dev-1/configuration.nix
      ./risoluto-dev-1/hardware-configuration.nix
    ];
  };
}
