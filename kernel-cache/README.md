# kernel-cache

This flake builds the CachyOS kernels `linux-cachyos-latest-lto-x86_64-v3` and
`linux-cachyos-latest-lto-zen4` (from
[nix-cachyos-kernel](https://github.com/xddxdd/nix-cachyos-kernel)), the NVIDIA
open kernel module for each, and the packages that hosts build against the
kernel. GitHub Actions pushes them to a public Cachix cache, so the NixOS hosts
that use them do not compile them. `hostPackages` in `flake.nix` lists the
extra packages each variant builds besides the kernel and its NVIDIA module. A failed build of any output stops the run before it
records the new revision, so no host moves to that kernel until the next run
succeeds.

The kernel's store path depends only on the nix-cachyos-kernel revision in
`flake.lock`, because the input's `pinned` overlay builds with the input's own
nixpkgs. A host gets a cache hit when it locks the same revision and uses the
`pinned` overlay. The NVIDIA module also needs the same `mkDriver` arguments
and patches as `hardware.nvidia.package` in `machines/nixos-rog/graphics.nix`.
Both import `nvidia-driver.nix`, which holds those shared arguments.
The hosts and this flake also extend the kernel package set with
`kernel-module-certs.nix`, which makes ryzen-smu, v4l2loopback and nct6687d
install through Kbuild, so their store paths are the same in both.

The build jobs and `scripts/build-local.sh` read no upstream binary cache, so
every kernel in the Cachix cache was compiled by this workflow or by that
script.

`flake.nix` pins nix-cachyos-kernel to a commit on its default branch. Upstream
builds and tests nothing before a commit lands there, so a person moves the pin
after reading the upstream diff, as
[docs/updates.md](../docs/updates.md#move-the-kernel-pin) describes.

This directory is its own flake with its own `flake.lock`, so it moves to a new
nix-cachyos-kernel revision first and the hosts follow only once the cache holds
that build.

The `variants` list in `flake.nix` names the CPU targets, and each builds in its
own job. The [`kernel-cache` workflow](../.github/workflows/kernel-cache.yml)
runs on a push to `main` that changes this flake, its driver arguments, its patches or the workflow,
and on a manual start. After the build and the push to Cachix succeed, it
commits `flake.lock` with `cached-paths.json`, which lists the
nix-cachyos-kernel revision, the kernel version and every pushed output path. A
host checks those paths in the cache before it locks the same revision.

The `check` workflow evaluates every package's derivation on pull requests and
pushes to `main`. `scripts/check-on-rog.sh` runs the same evaluation without a
build. A bad driver argument or missing patch fails that check before a merge.

The same cache holds packages that the root flake's hosts would compile, such
as DankMaterialShell. The
[`host-packages-cache` workflow](../.github/workflows/host-packages-cache.yml)
builds them from the hosts' own configuration;
[nixos-rog.md](../docs/nixos-rog.md#cached-packages) describes it.

Nothing unfree is pushed. The NVIDIA module builds from
[open-gpu-kernel-modules](https://github.com/NVIDIA/open-gpu-kernel-modules).
The host-packages-cache workflow does not push a package whose closure holds a
path that cache.nixos.org lacks and that is not a listed package, and that run
fails.

## Setup

- Repository variable `CACHIX_CACHE`: the Cachix cache name. Both workflows skip
  while it is unset.
- Repository secret `CACHIX_AUTH_TOKEN`: a Cachix token that may push to that
  cache.

## Building on another machine

A hosted runner has 4 CPUs, and a job stops at the 6-hour limit. When a compile
from source does not finish in that time, `scripts/build-local.sh` builds
variants in a `nixos/nix` container on a faster machine and pushes them to the
cache. With `--record` it then starts the `kernel-cache` workflow, which finds
every path in the cache and records the build.

```sh
CACHIX_AUTH_TOKEN=... scripts/build-local.sh --rev <nix-cachyos-kernel sha> --record zen4 x86_64-v3
```

The token comes from the environment; push only the outputs in `flake.nix`,
because the cache is public. The `kernel-cache` workflow can also be started by
hand for one revision: `gh workflow run kernel-cache -f rev=<sha>`. On
fedora-desktop,
[docs/updates.md](../docs/updates.md#when-the-cache-lacks-the-kernel) has the
command that reads the token from Infisical and the steps that follow.
