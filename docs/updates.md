# Update inputs, apps and the kernel

- [The kernel](#the-kernel)
- [Other inputs](#other-inputs)
- [Release tags](#release-tags)
- [Spotify and Spicetify](#spotify-and-spicetify)
- [Apps](#apps)

fedora-desktop has no Nix. `update-kernel.sh` needs none, so it runs there.
`move-inputs.sh` and `update-release-tags.sh` run `nix flake update`, and
`update-app.sh` runs `nix hash convert` for the Claude Desktop, ChatGPT and Grok
Bot packages. Run those scripts in a checkout on nixos-rog, which has Nix, `gh`
and `jq`. `update-app.sh antigravity-hub` and `update-app.sh openchamber` need
no Nix. The hourly updater on nixos-rog runs all four scripts ([nixos-rog.md](nixos-rog.md#hourly-updater)).

Each script changes files in that checkout and commits nothing. Commit the
change on a branch from a fresh `origin/main`, merge it, then deploy as
[deploy.md](deploy.md#deploy-a-merged-commit) describes.

## The kernel

To update the CachyOS kernel, move its input to the revision that the
[kernel-cache](../kernel-cache/README.md) workflow last built:

```sh
scripts/update-kernel.sh
```

The script first checks that every path the builder recorded for that revision
is in the `omerfarukoruc` Cachix cache. Those paths are the kernels, the NVIDIA
open modules, and ryzen-smu and turbostat for zen4. When one is missing, the
script leaves `flake.lock` unchanged. So a host never compiles the kernel
itself.

The script changes `flake.lock` and does not commit it. Commit the lock, then
deploy as [deploy.md](deploy.md#deploy) describes. The script prints a reminder
to do so only when its output is a terminal.

### When the cache lacks the kernel

When the script reports missing paths because the GitHub runner is slow or
timed out, build the revision on fedora-desktop instead:

1. Run this command. It takes the Cachix push token from Infisical, builds the
   variants in a `nixos/nix` container and pushes them. Then it starts the
   kernel-cache workflow to record them.

   ```sh
   cd ~/Desktop/workspace && CACHIX_AUTH_TOKEN=$(infisical secrets get CACHIX_AUTH_TOKEN_FEDORA_DESKTOP --plain --silent --env secrets --path /nixos-config) \
     ~/Desktop/workspace/nixos-config/kernel-cache/scripts/build-local.sh --rev <nix-cachyos-kernel sha> --record zen4 x86_64-v3
   ```

   The `cd` puts Infisical in the directory that holds its project file,
   `.infisical.json`. `<nix-cachyos-kernel sha>` is the full 40-character
   revision that `kernel-cache/flake.lock` locks on `main`, because
   `update-kernel.sh` compares the recorded paths with that revision:

   ```sh
   gh api 'repos/OmerFarukOruc/nixos-config/contents/kernel-cache/flake.lock?ref=main' --jq .content | base64 -d | jq -r '.nodes["nix-cachyos-kernel"].locked.rev'
   ```

   The [kernel-cache README](../kernel-cache/README.md#building-on-another-machine)
   has the other build options.

2. Wait until the run that the script started has finished. This command
   shows `completed`, `success` and a `createdAt` after the script ended. A
   result from an earlier run does not count.

   ```sh
   gh run list --repo OmerFarukOruc/nixos-config --workflow kernel-cache.yml --event workflow_dispatch --limit 1 --json status,conclusion,createdAt
   ```

3. Run `update-kernel.sh` again.

## Other inputs

`scripts/move-inputs.sh` moves flake inputs to their newest upstream. It moves
an input pinned to a release tag with `update-release-tags.sh`, and an input
that follows a branch to the head of that branch with `nix flake update`. An
input pinned to a commit, such as `kwin-effects-glass`, stays where it is. To
move it, change its commit in `flake.nix`, then run
`nix flake update kwin-effects-glass` and check that `git diff flake.lock` shows
the new revision.

`move-inputs.sh` never moves the kernel or llm-agents, because each of them
moves only once a cache holds its builds. It takes the same arguments as
`update-release-tags.sh`. The updater on nixos-rog and the host-packages-cache
workflow both run it.

A plain `nix flake update` moves every input without a cache check. A host may
then compile the kernel, the llm-agents packages, and the packages built from
nixpkgs, dms and sops-nix. Move the kernel with
`scripts/update-kernel.sh`. Move nixpkgs, dms and sops-nix by hand
only after the host-packages-cache workflow
([nixos-rog.md](nixos-rog.md#cached-packages)) has pushed the packages for the
lock you will deploy. The workflow builds the lock that `scripts/move-inputs.sh`
produces. To move one input by hand, use `nix flake update <input>`, or
`scripts/update-release-tags.sh <input>` for an input pinned to a release tag.
The updater moves llm-agents once cache.numtide.com holds its builds
([nixos-rog.md](nixos-rog.md#hourly-updater)).

## Release tags

`scripts/update-release-tags.sh` moves inputs pinned to a GitHub release tag
(`github:owner/repo/v1.2.3` in `flake.nix`) to that repository's newest release
and locks them. It moves one of these sets:

- all of them
- only the inputs named
- with `--except`, all but those

## Spotify and Spicetify

`home-manager/modules/spicetify.nix` builds Spotify from `nixpkgs-spotify` and
patches it with `spicetify-nix`. Both inputs pin a commit, so the updater never
moves them. A Spotify release that the spicetify-cli release cannot patch still
builds, then opens a blank window. To move them:

1. Set both commits in `flake.nix`, then run
   `nix flake update nixpkgs-spotify spicetify-nix` on nixos-rog.
2. Read the `spotify` and `spicetify-cli` versions at the new nixpkgs commit. The
   "Compatibility" list in the notes of that
   [spicetify-cli release](https://github.com/spicetify/cli/releases) must
   include the Linux Spotify version.
3. Merge, deploy nixos-rog, and launch Spotify. If the window is blank, revert
   the commit and deploy again.

## Apps

`scripts/update-app.sh NAME` moves `pkgs/NAME.nix` to the vendor's newest
release, with no waiting period, and prints the new version. It
prints nothing when the app is current or when the package names no release
source.

Antigravity, ChatGPT, Claude Desktop, Grok Bot and OpenChamber name their
release source.
airpods-tui, herdr, KVitals and Smart Video Wallpaper name none, so `update-app.sh` leaves
them and their version and hash move by hand.

Before you decide that a vendor publishes no release source, read the `.deb`'s
`postinst` (`dpkg-deb -e <deb> <dir>`). Grok Bot's registers the APT
repository that its `passthru.aptIndex` names.

| App | Release source |
| --- | --- |
| Claude Desktop, ChatGPT, Grok Bot | an APT index in `passthru.aptIndex` |
| Antigravity, OpenChamber | its electron-builder feed (`latest-x64-linux.yml`, `latest-linux.yml`) in `passthru.releaseFeed`; for Antigravity, `update-app.sh` also moves the build ID in its URL |

The updater on nixos-rog builds each moved app on its own first. A version that
does not build stays out of the update and sends one notification, which
quotes the build's last error line. The other updates go ahead.

When an app's update check fails, the app stays where it is. Examples are an
unreadable feed or index, or a feed file that is not the one the package
downloads. The updater sends one notification per distinct error, until a
check succeeds.
