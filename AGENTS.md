# Hosts

- Change `nixos-latitude` and `nixos-rog` only through this repository. `deploy.sh` builds from a copy of this checkout, so an edit to a host's `/etc/nixos` never reaches the system.
- Deploy every merged change to each host it affects without asking again, as [docs/deploy.md](docs/deploy.md#deploy) describes. A host is affected when its system `drvPath` changes; compare it for both hosts with the "What an edit rebuilds or restarts" lookup below.
- [CONTEXT.md](CONTEXT.md) defines the domain terms (login session, hybrid mode, integrated mode) and each host's SSH alias.
- nixos-rog's hourly updater squash-merges input and app moves to `main`, so `main` and `flake.lock` move often. Branch from a freshly fetched `origin/main` ([docs/nixos-rog.md](docs/nixos-rog.md#hourly-updater)).
- Host packages are tools that Omer or a coding agent runs by hand. Linters, formatters and scanners come from a project's own dev shell through direnv.

# Checks

fedora-desktop has no Nix, so these scripts run Nix on a copy of this checkout on nixos-rog. [README.md](README.md#everyday-commands) lists every script.

- Before a commit, run `scripts/check-on-rog.sh --fix`. It formats, then runs CI's formatter check and `nix flake check` with import from derivation off.
- Print one configuration value with `scripts/eval-on-rog.sh <attribute>`.
- Before deploying a new or changed systemd `script`, run it with `scripts/run-unit-on-rog.sh <unit>`.
- Before changing power, fan or heat settings, read [Power and heat](docs/nixos-rog.md#power-and-heat). It names the one owner of each setting and the `scripts/thermal-test-rog.sh` load test.
- For a change visible on screen, follow [Check a visual change](docs/nixos-rog.md#check-a-visual-change).

# Nixpkgs

- `flake.lock` holds more than one nixpkgs node. Ours is the one the root input names: `jq -r '.nodes.root.inputs.nixpkgs as $n | "\($n) \(.nodes[$n].locked.rev)"' flake.lock`. llm-agents and nix-cachyos-kernel keep their own nixpkgs on purpose, so their binary caches still match.
- Fix a nixpkgs package with an overlay in `overlays/` (`overrideAttrs` with patches). `nixpkgs.overlays` in `nixosModules/common.nix` lists every overlay, so extend the package's existing overlay or add the new file to that list. Fix a NixOS module with `disabledModules` plus the module from a second pinned nixpkgs input. Patching nixpkgs itself needs import from derivation, which CI forbids.
- A text edit in a build step fails the build when it changes nothing. Use `substituteInPlace --replace-fail`; after a `sed`, or a `--replace-quiet` where a release may use either of two forms, check the result with `grep`.

# Lookups

Look up a Nix name, hash or rebuild cause before you write it. The tools run on nixos-rog; from fedora-desktop, quote the whole command, as in `ssh nixos-rog '<command>'`, so that `$(...)` expands on rog. They read upstream nixpkgs, not `flake.lock`, so `scripts/eval-on-rog.sh` stays the source for a value in this configuration. Claude Code also has a `nixos` MCP server that searches search.nixos.org.

- Option, package or `lib` name: `nix-search-tv print --indexes <nixos|home-manager|nixpkgs|noogle> | grep <word>`, then `nix-search-tv preview --indexes <index> --json <name>` for its type, default and declaration. Exit 1 means the name does not exist. plasma-manager options are not indexed.
- Source hash or fetcher block: `nix run nixpkgs#nurl -- --json <url> <rev>`.
- Draft of a new package with its vendor hash: `NIX_PATH=nixpkgs=$(nix eval --raw nixpkgs#path) nix run nixpkgs#nix-init -- --headless --url <url> --rev <tag> /tmp/draft.nix </dev/null`, then edit the draft.
- What an edit rebuilds or restarts: print the system `drvPath` for the change and for `origin/main` (a clean worktree) with `scripts/eval-on-rog.sh '.#nixosConfigurations.<host>.config.system.build.toplevel.drvPath'`, then run `nix run nixpkgs#nix-diff -- --color never --skip-already-compared <old.drv> <new.drv> | head -n 200 | cut -c1-300` on rog.
- Why a package is in the running system: `nix why-depends /run/current-system <store path>`.
- Which nixpkgs advance broke a build: in a copy of the checkout, because `npc` rewrites `flake.lock`, run `npc fetch`, then `npc bisect start --input nixpkgs nixos-unstable` and `npc bisect good|bad`, each as `nix run nixpkgs#npc -- <subcommand>`.
