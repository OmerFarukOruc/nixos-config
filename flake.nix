{
  description = "NixOS hosts of Omer's desktop and laptops";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    nix-cachyos-kernel.url = "github:xddxdd/nix-cachyos-kernel/release";
    base16.url = "github:SenchoPens/base16.nix";
    base16-schemes = {
      url = "github:tinted-theming/schemes/spec-0.11";
      flake = false;
    };
    # The VS Code and Neovim themes of the warm-burnout-* schemes in
    # assets/schemes, which color syntax beyond the 16 Base16 slots. The
    # schemes copy this revision's palette (v1.8.0), so a commit pin keeps the
    # updater from moving the themes away from them.
    warm-burnout = {
      url = "github:felipefdl/warm-burnout/e45c7717e430d8f12a9b9b26145c0456b0c7a319";
      flake = false;
    };
    # The VS Code theme template that home-manager/modules/theme.nix renders
    # with the scheme for every scheme but the warm-burnout-* ones. A commit
    # pin keeps the update workflow from changing the template.
    tinted-vscode = {
      url = "github:tinted-theming/tinted-vscode/3beb4614b6eea1ce60524a404977ee16ff931bfb";
      flake = false;
    };
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    dms = {
      url = "github:AvengeMedia/DankMaterialShell/v2.0.0";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # No nixpkgs follows, because cache.numtide.com holds builds for its own nixpkgs.
    llm-agents.url = "github:numtide/llm-agents.nix";
    nvf = {
      url = "github:NotAShelf/nvf";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    plasma-manager = {
      url = "github:nix-community/plasma-manager";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.home-manager.follows = "home-manager";
    };
    # Most Glass fixes land on main after its latest tag, so this pins a commit.
    kwin-effects-glass = {
      url = "github:4v3ngR/kwin-effects-glass/2ef07fa1a2a062da12289ad8de1393e01f5c1d8e";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # The Qt style and window decoration that match the Glass effect. The
    # repository has no tags, so this pins a commit.
    glass-style = {
      url = "github:4v3ngR/Glass/81edfa7f7f0d74997ab730598fa32805b20e4040";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # The launcher, dock task manager and OLED pixel shift of the macOS Tahoe
    # Plasma theme. Its task manager is a compiled applet that loads only into
    # the Plasma it was built for, so the modules build it with lib.mkPackages
    # and our pkgs. A commit pin keeps the update workflow from moving it,
    # and the hosts from rebuilding it, for every upstream move.
    mac-tahoe = {
      url = "github:lestercorderomurillo/macos-tahoe-liquid-kde/6d7802faae8d306dd00f4a3d1fc0a8c47d46e827";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.home-manager.follows = "home-manager";
    };
    # HushMic builds from source with no binary cache, so a commit pin keeps
    # the update workflow from moving it, and the hosts from rebuilding it, for
    # every upstream move.
    hushmic = {
      url = "github:Fovty/hushmic-nix/b2af2236e162a1d3454bc479125b6cb2a31fc029";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nixpkgs-spotify.url = "github:nixos/nixpkgs/7fd4004d0511991fff3a0524856a9be09e28c5f0";
    spicetify-nix = {
      url = "github:Gerg-L/spicetify-nix/50246f67d72e042291e426823dd61567b796fea9";
      inputs.nixpkgs.follows = "nixpkgs-spotify";
    };
    # Google Chrome 156 and Tailscale 1.104.2 carry security fixes and are on
    # nixpkgs master but not yet on nixos-unstable. applications.nix and
    # tailscale.nix take each package from here only while it is newer than
    # the one in nixpkgs. Remove this input once nixpkgs has both versions.
    nixpkgs-security.url = "github:nixos/nixpkgs/1325d382e38ad08c924d600233e7706865d15b84";
    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nix-index-database = {
      url = "github:nix-community/nix-index-database";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    vscode-vibrancy = {
      url = "github:illixion/vscode-vibrancy-continued/v1.6.0";
      flake = false;
    };
    stay-green = {
      url = "github:OmerFarukOruc/stay-green";
      flake = false;
    };
  };

  outputs =
    inputs:
    let
      inventory = import ./machines/inventory.nix { inherit inputs; };
      tooling = import ./tooling.nix { inherit inputs; };
      box = inventory.nixosConfigurations.devbox;
    in
    {
      inherit (inventory) nixosConfigurations;
      inherit (tooling) formatter;
      checks.x86_64-linux =
        import ./ci/server-boot.nix {
          inherit inputs;
          host = box;
        }
        // import ./ci/server-units.nix {
          inherit inputs;
          host = box;
        }
        // import ./ci/server-desktop.nix {
          inherit inputs;
          host = box;
        }
        // import ./ci/self-deploy.nix {
          inherit inputs;
          host = box;
        }
        // import ./ci/scheme-catalogue.nix { inherit inputs; };
    };
}
