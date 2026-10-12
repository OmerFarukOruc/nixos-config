# Update inputs, apps and the kernel

To update the CachyOS kernel, move its input to the revision that the
[kernel-cache](../kernel-cache/README.md) workflow last built.
The script first checks that the kernel and the NVIDIA open module of that
revision are in the `omerfarukoruc` Cachix cache, and leaves `flake.lock`
unchanged when they are not, so a host never compiles the kernel itself:

```sh
scripts/update-kernel.sh
```

When the script reports missing paths because the GitHub runner is slow or timed
out, build the revision on fedora-desktop instead. This takes the Cachix push
token from Infisical, builds the variants in a `nixos/nix` container, pushes
them, and starts the kernel-cache workflow to record them; run `update-kernel.sh`
again once that workflow finishes:

```sh
cd ~/Desktop/workspace && CACHIX_AUTH_TOKEN=$(infisical secrets get CACHIX_AUTH_TOKEN_FEDORA_DESKTOP --plain --silent --env secrets --path /nixos-config) \
  ~/Desktop/workspace/nixos-config/kernel-cache/scripts/build-local.sh --rev <nix-cachyos-kernel sha> --record zen4 x86_64-v3
```

`nix flake update` moves the kernel input too. Use `nix flake update <input>`
for the other inputs.

`scripts/update-release-tags.sh` moves inputs pinned to a GitHub release tag
(`github:owner/repo/v1.2.3` in `flake.nix`) to that repository's newest release
and locks them: all of them, only the inputs named, or with `--except` all but
those.

`scripts/update-app.sh NAME` moves `pkgs/NAME.nix` to the vendor's newest
release, and prints it, or prints nothing when it is current. Claude Desktop and
ChatGPT name an APT index in `passthru.aptIndex`; OpenChamber names its
electron-builder feed (`latest-linux.yml`) in `passthru.releaseFeed`. A feed
release moves its app only once it is 3 days old, by the feed's `releaseDate`.
The auto-updater builds each moved app on its own first. A version that does not
build stays out of the update and sends one notification, so the other updates
go ahead. An app whose update check fails (an unreadable feed or index, or a
feed file that is not the one the package downloads) stays where it is and
sends one notification per distinct error, until a check succeeds.
