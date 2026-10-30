# Update inputs, apps and the kernel

- [Update by hand](#update-by-hand)
- [The kernel](#the-kernel)
- [Other inputs](#other-inputs)
- [Release tags](#release-tags)
- [Spotify and Spicetify](#spotify-and-spicetify)
- [Apps](#apps)

`update-kernel.sh` needs no Nix.
`move-inputs.sh` and `update-release-tags.sh` run `nix flake update`, and
`update-app.sh` runs `nix hash convert` for the Grok Bot package, npm and
`prefetch-npm-deps` through Nix for cf and openchamber-web, and a build for the
apps with a GitHub release source. Run those scripts in a
checkout on nixos-desktop or nixos-rog, which have Nix, `gh` and `jq`.
`update-app.sh antigravity-hub`, `update-app.sh openchamber` and
`update-app.sh impeccable` need no Nix. `scripts/prepare-update.sh` runs all
four scripts, and `devenv update` for `devenv.lock`
([Update by hand](#update-by-hand)).

Each script changes files in that checkout and commits nothing. Commit the
change and push it to `main` as [AGENTS.md](../AGENTS.md) describes, then
deploy as [deploy.md](deploy.md#deploy-a-change-on-main) describes.

## Update by hand

Inputs and apps move only when a person or an agent runs the update. No
workflow or timer moves them. Run it on nixos-desktop or nixos-rog, in a
worktree on a branch from a freshly fetched `origin/main`:

1. Move the apps. The script moves each app in `pkgs/` with `update-app.sh`
   and keeps a move only when the app builds on its own. It writes the commit
   body, one `- APP: VERSION` line per moved app, to the file named last, and
   commits nothing:

   ```sh
   scripts/prepare-update.sh apps nixos-rog /tmp/apps-changes
   if test -s /tmp/apps-changes; then
     git add -u -- pkgs
     printf '%s\n\n' 'chore(pkgs): update apps to their newest releases' | cat - /tmp/apps-changes | git commit -F -
   fi
   git status --short
   ```

2. Move the inputs. The script moves every input that the table below does
   not name with `move-inputs.sh`, and the inputs in the table by the rules
   there. When a host's system no longer evaluates after those moves, nixpkgs
   stays where it is, and when that is not enough, every input does. An app
   with a `passthru.depsBun` line moves again, because its dependency hash
   follows nixpkgs' bun. When something moved, it also moves `devenv.lock`
   with `devenv update`, while the dev shell of `devenv.nix` still builds with
   it:

   ```sh
   scripts/prepare-update.sh inputs nixos-rog /tmp/inputs-changes
   if test -s /tmp/inputs-changes; then
     git add -u -- flake.nix flake.lock devenv.lock pkgs
     printf '%s\n\n' 'chore(flake): update inputs to their newest releases' | cat - /tmp/inputs-changes | git commit -F -
   fi
   git status --short
   ```

   An empty changes file means nothing moved, so the block makes no commit.
   After each block, `git status --short` must print nothing. A file it lists
   changed outside the commit, so the build in step 3 would test a tree that
   step 4 does not push; find out which script changed it before you go on.

3. Build nixos-rog's system with `scripts/build.sh`. `devenv tasks run ci`
   builds every host's system instead
   ([Check before you deploy](deploy.md#check-before-you-deploy)).
4. Push to `main` and deploy as [AGENTS.md](../AGENTS.md) describes.

Both modes take the host whose system decides the moves, and need nix, `gh`,
curl, jq and python3. A move that stays out prints a `warning:` line on
stderr that names the cause, and the other moves go ahead.

A package test that fails in the build of step 3 is a bug. Fix it in
`overlays/` before the push, as [Nixpkgs](../AGENTS.md#nixpkgs) describes. A
passing rerun does not clear it, because the test can fail again on the next
build of that package.

| Input | When it moves |
| --- | --- |
| kernel | Only when a cache holds its build. `update-kernel.sh` moves it. |
| llm-agents | Only when a cache holds its builds. See the paragraph below. |
| kwin-effects-glass, glass-style, hushmic, nixpkgs-spotify, spicetify-nix, tinted-vscode and warm-burnout | Never. Their `flake.nix` URLs pin a commit, so moving one is a hand edit. |

When the new llm-agents revision has a coding agent that cache.numtide.com does
not hold yet for the host's system, or the script cannot tell, llm-agents stays
where it is. So the laptop does not compile an agent at full load. The next
update tries again.

## The kernel

To update the CachyOS kernel, move its input to the revision that the
[kernel-cache](../kernel-cache/README.md) workflow last built:

```sh
scripts/update-kernel.sh
```

The script first checks that every path the builder recorded for that revision
is in the `omerfarukoruc` Cachix cache, which `nixosModules/kernel.nix` adds as a
substituter. The kernel-cache workflow builds the cache's contents. Those paths are
the kernels, the NVIDIA open modules, and ryzen-smu, turbostat and nct6687d for
zen4. When one is missing, the script leaves `flake.lock` unchanged. So a host
never compiles the kernel itself. A plain `nix flake update` does not check the
cache.

The script changes `flake.lock` and does not commit it. Commit the lock, then
deploy as [deploy.md](deploy.md#deploy) describes. The script prints a reminder
to do so only when its output is a terminal.

### Move the kernel pin

`kernel-cache/flake.nix` pins nix-cachyos-kernel to a commit on upstream's
default branch, and nothing moves that pin on its own. No upstream build tests
those commits, so read what changed upstream since the pin before you move it:

```sh
gh api 'repos/xddxdd/nix-cachyos-kernel/compare/<old sha>...<new sha>' --jq '.files[] | "\(.status) +\(.additions) -\(.deletions) \(.filename)"'
```

A commit from upstream's update workflow changes only `flake.lock` and
`kernel-cachyos/version.json`. Check that each new URL in `version.json` points
at a CachyOS repository and each new input in `flake.lock` at its usual owner.
Read every other changed file in full.

Then change the commit in `kernel-cache/flake.nix`, run
`scripts/check.sh --fix`, which locks the new commit in
`kernel-cache/flake.lock`, and push the change to `main`. The push starts the
kernel-cache workflow, which builds and records the new revision. The workflow
checks out the tip of `main`, not the commit that queued the run. A run that
waited behind another one would otherwise build its older lock and record it over
the newer one. The next [update by hand](#update-by-hand) then moves the hosts
with `update-kernel.sh`.

### When the cache lacks the kernel

When the script reports missing paths because the GitHub runner is slow or
timed out, build the revision on nixos-desktop instead:

1. Run this command. It takes the Cachix push token from Infisical, builds the
   variants in a `nixos/nix` container and pushes them. Then it starts the
   kernel-cache workflow to record them.

   ```sh
   cd ~/Desktop/workspace && CACHIX_AUTH_TOKEN=$(infisical secrets get CACHIX_AUTH_TOKEN_NIXOS_DESKTOP --plain --silent --env secrets --path /nixos-config) \
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

To add an input, write it in `flake.nix` and run `scripts/check.sh --fix`.
It locks each input that `flake.lock` lacks or whose URL changed, and copies
`flake.lock` back. Without `--fix`, the check fails while `flake.lock` lacks an
input, and so does the pre-push hook.

`move-inputs.sh` never moves the kernel or llm-agents, because each of them
moves only once a cache holds its builds. It moves every input, or only the
inputs it names. `prepare-update.sh inputs` runs it.

A plain `nix flake update` moves every input without a cache check. A host may
then compile the kernel and the llm-agents packages. Move the kernel with
`scripts/update-kernel.sh`. To move one input by hand, use `nix flake update <input>`, or
`scripts/update-release-tags.sh <input>` for an input pinned to a release tag.
`prepare-update.sh inputs` moves llm-agents once cache.numtide.com holds its
builds ([Update by hand](#update-by-hand)).

## Release tags

`scripts/update-release-tags.sh` moves inputs pinned to a GitHub release tag
(`github:owner/repo/v1.2.3` in `flake.nix`) to that repository's newest release
and locks them. It moves one of these sets:

- all of them
- only the inputs named
- with `--except`, all but those

## Spotify and Spicetify

`home-manager/modules/spicetify.nix` builds Spotify from `nixpkgs-spotify` and
patches it with `spicetify-nix`. Both inputs pin a commit, so `move-inputs.sh`
never moves them. A Spotify release that the spicetify-cli release cannot patch still
builds, then opens a blank window. To move them:

1. Set both commits in `flake.nix`, then run
   `nix flake update nixpkgs-spotify spicetify-nix`.
2. Read the `spotify` and `spicetify-cli` versions at the new nixpkgs commit. The
   "Compatibility" list in the notes of that
   [spicetify-cli release](https://github.com/spicetify/cli/releases) must
   include the Linux Spotify version.
3. Push to `main`, then run `./deploy.sh <host> switch` for each host that
   `scripts/affected-hosts.sh <old>..<sha>` prints. Launch Spotify on nixos-rog. If
   the window is blank, revert the commit and deploy those hosts again.

## Apps

`scripts/update-app.sh NAME` moves `pkgs/NAME.nix` to the vendor's newest
release, with no waiting period, and prints the new version. It
prints nothing when the app is current or when the package names no release
source.

Every app in `pkgs/` with an upstream release names its release source. The
others are this repository's own code or follow a flake input: claude-tools,
the Claude accounts widget, the Mac Tahoe plasmoids, the glass Plasma style and
stay-green. ChatGPT, Claude Desktop and herdr come from the llm-agents input
and move with it.

Before you decide that a vendor publishes no release source, read the `.deb`'s
`postinst` (`dpkg-deb -e <deb> <dir>`). Grok Bot's registers the APT
repository at `downloads.cursor.com` that its `passthru.aptIndex` names. That
repository's package record names SpaceXAI as the vendor.

| App | Release source |
| --- | --- |
| Grok Bot | an APT index in `passthru.aptIndex` |
| Antigravity, OpenChamber | its electron-builder feed (`latest-x64-linux.yml`, `latest-linux.yml`) in `passthru.releaseFeed`; for Antigravity, `update-app.sh` also moves the build ID in its URL |
| airpods-tui, herdr web UI, KVitals, linctl, Smart Video Wallpaper | the newest GitHub release tagged v and digits, in `passthru.githubRepo`; `update-app.sh` sets the source hash, then builds once with a placeholder to learn the dependencies' hash: `cargoHash` for airpods-tui, `vendorHash` for linctl, and the `outputHash` of the Bun dependencies for the herdr web UI. `passthru.depsBun` holds the bun version that produced the herdr web UI's hash, so `update-app.sh` learns the hash again when nixpkgs' bun differs |
| cf, impeccable, OpenChamber's web server | the `latest` dist-tag of the npm package in `passthru.npmPackage`; for cf and `openchamber-web`, whose `pkgs/NAME/` holds a wrapper `package.json` and its lockfile, `update-app.sh` writes both again and sets `npmDepsHash` |

The wrapper `package.json` of cf depends on cf, because cf has only beta releases
and its own `package.json` pins dev dependencies that do not resolve. The wrapper
of `openchamber-web` depends on `@openchamber/web`, the web server that
devbox runs. `pkgs/openchamber.nix` is the OpenChamber desktop app. The
`workerd` binary that `cf dev` runs goes through nix-ld
(`nixosModules/common.nix`).

`prepare-update.sh apps` builds each moved app on its own first. A version
that does not build stays where it is, and the script prints a warning that
quotes the build's last error line. The other apps still move. The apps land
as their own commit, so a failing input move does not hold them back
([Update by hand](#update-by-hand)).

When an app's update check fails, the app stays where it is. Examples are an
unreadable feed or index, or a feed file that is not the one the package
downloads. Each run prints the error as a warning until a check succeeds.
