# Update inputs, apps and the kernel

## The kernel

To update the CachyOS kernel, move its input to the revision that the
[kernel-cache](../kernel-cache/README.md) workflow last built:

```sh
scripts/update-kernel.sh
```

The script first checks that the kernel and the NVIDIA open module of that
revision are in the `omerfarukoruc` Cachix cache. When they are not, the script
leaves `flake.lock` unchanged. So a host never compiles the kernel itself.

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

2. Wait until that workflow finishes.
3. Run `update-kernel.sh` again.

## Other inputs

`nix flake update` moves the kernel input too. For the other inputs, use
`nix flake update <input>`.

## Inputs

`scripts/move-inputs.sh` moves flake inputs to their newest upstream. It moves
an input pinned to a release tag with `update-release-tags.sh`, and any other
to the head of its branch with `nix flake update`. It never moves the kernel or
llm-agents, because each of them moves only once a cache holds its builds. It
takes the same arguments as `update-release-tags.sh`. The updater on nixos-rog
and the host-packages-cache workflow both run it.

## Release tags

`scripts/update-release-tags.sh` moves inputs pinned to a GitHub release tag
(`github:owner/repo/v1.2.3` in `flake.nix`) to that repository's newest release
and locks them. It moves one of these sets:

- all of them
- only the inputs named
- with `--except`, all but those

## Apps

`scripts/update-app.sh NAME` moves `pkgs/NAME.nix` to the vendor's newest
release and prints it. It prints nothing when the app is current.

Each package names where its releases come from:

| App | Release source |
| --- | --- |
| Claude Desktop, ChatGPT | an APT index in `passthru.aptIndex` |
| OpenChamber | its electron-builder feed (`latest-linux.yml`) in `passthru.releaseFeed` |

A feed release moves its app only once it is 3 days old, by the feed's
`releaseDate`.

The updater on nixos-rog builds each moved app on its own first. A version that
does not build stays out of the update and sends one notification. The other
updates go ahead.

When an app's update check fails, the app stays where it is. Examples are an
unreadable feed or index, or a feed file that is not the one the package
downloads. The updater sends one notification per distinct error, until a
check succeeds.
