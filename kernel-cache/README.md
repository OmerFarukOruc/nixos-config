# kernel-cache

Builds the CachyOS kernel (`linux-cachyos-latest-lto-x86_64-v3` and
`linux-cachyos-latest-lto-zen4` from
[nix-cachyos-kernel](https://github.com/xddxdd/nix-cachyos-kernel)) and the
NVIDIA open kernel module for each on GitHub Actions, plus `ryzen-smu` and
`turbostat` for zen4, and pushes them to a public Cachix cache, so the NixOS
hosts that use them do not compile them. `hostPackages` in `flake.nix` lists
what each variant's hosts build against the kernel. A failed build of any of
them stops the run before it records the new revision, so no host moves to that
kernel until the next run succeeds.

The kernel's store path depends only on the nix-cachyos-kernel revision in
`flake.lock`, because the input's `pinned` overlay builds with the input's own
nixpkgs. A host gets a cache hit when it locks the same revision and uses the
`pinned` overlay. The NVIDIA module also needs the same `mkDriver` arguments as
the host's `hardware.nvidia.package`.

The same path is what upstream's Hydra builds, so the build jobs and
`scripts/build-local.sh` also read upstream's binary cache
(`https://attic.xuyh0120.win/lantian`). A kernel still in that cache is
downloaded and pushed to Cachix instead of compiled. That cache keeps outputs
for a few days only, so it helps when the `release` branch has just moved.

This directory is its own flake with its own `flake.lock`, so the builder moves
to a new revision first and the hosts follow only once the cache holds it.

The `variants` list in `flake.nix` names the CPU targets; each one builds in
its own job. The
[`kernel-cache` workflow](../.github/workflows/kernel-cache.yml) builds on every
push to `main` that changes this flake or its patches, and once a day after moving
`flake.lock` to the head of the upstream `release` branch. After the build and
the push to Cachix succeed, it commits `flake.lock` with `cached-paths.json`,
which lists the nix-cachyos-kernel revision, the kernel version and every pushed
output path. A host checks
those paths in the cache before it locks the same revision.

The same cache holds packages that the root flake's hosts would compile, such
as DankMaterialShell. The
[`host-packages-cache` workflow](../.github/workflows/host-packages-cache.yml)
builds them from the hosts' own configuration;
[nixos-rog.md](../docs/nixos-rog.md#cached-packages) describes it.

Nothing unfree is pushed. The NVIDIA module builds from
[open-gpu-kernel-modules](https://github.com/NVIDIA/open-gpu-kernel-modules).
The host-packages-cache workflow fails before the push when a closure holds a
path that cache.nixos.org lacks and that is not a listed package.

## Setup

- Repository variable `CACHIX_CACHE`: the Cachix cache name. Both workflows skip
  while it is unset.
- Repository secret `CACHIX_AUTH_TOKEN`: a Cachix token that may push to that
  cache.

## Building on another machine

A hosted runner has 4 CPUs, and an LTO kernel takes it about 2 to 4 hours, close
to the job's 6-hour limit. `scripts/build-local.sh` builds variants in a
`nixos/nix` container on a faster machine and pushes them to the cache. With
`--record` it then starts the `kernel-cache` workflow, which finds every path in the cache and
records the build.

```sh
CACHIX_AUTH_TOKEN=... scripts/build-local.sh --rev <nix-cachyos-kernel sha> --record zen4 x86_64-v3
```

The token comes from the environment; push only the outputs in `flake.nix`,
because the cache is public. The `kernel-cache` workflow can also be started by hand
for one revision: `gh workflow run kernel-cache -f rev=<sha>`.
