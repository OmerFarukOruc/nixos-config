# Host rules

- Manage `nixos-latitude` and `nixos-rog` through this repository, not by editing `/etc/nixos` directly on a host.
- Deploy every merged change to the hosts it affects, per docs/deploy.md.
- fedora-desktop has no Nix. Evaluate, check, or run a unit script from this checkout with the `scripts/*-on-rog.sh` scripts, and stress-test nixos-rog's CPU or GPU with `scripts/thermal-test-rog.sh` (README.md, Commands).
- Install only tools Omer types by hand on this host. Do not install scanners on the host. Use per-project toolchains via direnv.

# Nixpkgs

- `flake.lock` holds more than one nixpkgs node. Ours is the one the root input names: `jq -r '.nodes.root.inputs.nixpkgs as $n | "\($n) \(.nodes[$n].locked.rev)"' flake.lock`. llm-agents and nix-cachyos-kernel keep their own nixpkgs on purpose, so their binary caches still match.
- Fix a nixpkgs package with an overlay in `overlays/` (`overrideAttrs` with patches); the first fix creates the directory. Fix a NixOS module with `disabledModules` plus the module from a second pinned nixpkgs input. Patching nixpkgs itself needs import from derivation, which CI forbids.
- A text edit in a build step fails the build when it changes nothing. Use `substituteInPlace --replace-fail`; after a `sed`, or a `--replace-quiet` where a release may use either of two forms, check the result with `grep`.
