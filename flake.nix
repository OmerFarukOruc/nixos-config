{
  description = "NixOS hosts managed from fedora-desktop";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    # scripts/update-kernel.sh moves this input, only to a revision that the
    # kernel-cache workflow has built. scripts/move-inputs.sh skips it.
    nix-cachyos-kernel.url = "github:xddxdd/nix-cachyos-kernel/release";
    base16.url = "github:SenchoPens/base16.nix";
    base16-schemes = {
      url = "github:tinted-theming/schemes/spec-0.11";
      flake = false;
    };
    # The VS Code and Neovim themes of the warm-burnout-* schemes in
    # assets/schemes, which color syntax beyond the 16 Base16 slots. The
    # schemes copy this revision's palette (v1.8.0), so a commit pin keeps the
    # hourly updater from moving the themes away from them.
    warm-burnout = {
      url = "github:felipefdl/warm-burnout/e45c7717e430d8f12a9b9b26145c0456b0c7a319";
      flake = false;
    };
    # The VS Code theme template that home-manager/modules/theme.nix renders
    # with the scheme for every scheme but the warm-burnout-* ones. A commit
    # pin keeps the hourly updater from changing the template.
    tinted-vscode = {
      url = "github:tinted-theming/tinted-vscode/3beb4614b6eea1ce60524a404977ee16ff931bfb";
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
    # and our pkgs. A commit pin keeps the hourly updater from rebuilding it
    # for every upstream move.
    mac-tahoe = {
      url = "github:lestercorderomurillo/macos-tahoe-liquid-kde/8fac9286e6687bf3a890edfca68659bb8e576c72";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.home-manager.follows = "home-manager";
    };
    # HushMic builds from source with no binary cache, so a commit pin keeps
    # the hourly updater from rebuilding it on rog for every upstream move.
    hushmic = {
      url = "github:Fovty/hushmic-nix/b2af2236e162a1d3454bc479125b6cb2a31fc029";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # Spicetify patches Spotify at build time. A Spotify release that the
    # spicetify-cli release cannot patch still builds and opens a blank window,
    # so these commit pins keep the hourly updater from shipping one.
    nixpkgs-spotify.url = "github:nixos/nixpkgs/7fd4004d0511991fff3a0524856a9be09e28c5f0";
    spicetify-nix = {
      url = "github:Gerg-L/spicetify-nix/50246f67d72e042291e426823dd61567b796fea9";
      inputs.nixpkgs.follows = "nixpkgs-spotify";
    };
    sops-nix = {
      url = "github:Mic92/sops-nix";
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
