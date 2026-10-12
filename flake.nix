{
  description = "NixOS hosts managed from fedora-desktop";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    nix-cachyos-kernel.url = "github:xddxdd/nix-cachyos-kernel/release";
    base16.url = "github:SenchoPens/base16.nix";
    base16-schemes = {
      url = "github:tinted-theming/schemes/spec-0.11";
      flake = false;
    };
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    dms = {
      url = "github:AvengeMedia/DankMaterialShell/v1.6.3";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # No nixpkgs follows: cache.numtide.com holds builds for its own nixpkgs.
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
      url = "github:4v3ngR/kwin-effects-glass/32f1e79f517eef992563856aa06963f6ee8455b9";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # The Qt style and window decoration that match the Glass effect. The
    # repository has no tags, so this pins a commit.
    glass-style = {
      url = "github:4v3ngR/Glass/81edfa7f7f0d74997ab730598fa32805b20e4040";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    silent-sddm = {
      url = "github:uiriansan/SilentSDDM";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # A prebuilt nix-index database, refreshed weekly upstream, for comma and
    # command-not-found.
    nix-index-database = {
      url = "github:nix-community/nix-index-database";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # The runtime that home-manager/modules/vscode.nix patches into VS Code.
    vscode-vibrancy = {
      url = "github:illixion/vscode-vibrancy-continued/v1.4.0";
      flake = false;
    };
  };

  outputs =
    inputs:
    import ./machines/inventory.nix { inherit inputs; } // import ./tooling.nix { inherit inputs; };
}
