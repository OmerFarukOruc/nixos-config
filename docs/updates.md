# Update inputs, apps and the kernel

- [Update by hand](#update-by-hand)
- [The kernel](#the-kernel)
- [Other inputs](#other-inputs)
- [Release tags](#release-tags)
- [Spotify and Spicetify](#spotify-and-spicetify)
- [Apps](#apps)

The `update` workflow (`.github/workflows/update.yml`) runs `ci/update.sh`
on GitHub every 2 hours. It runs the two steps of
[Update by hand](#update-by-hand), apps and then inputs, commits each move,
runs `ci/checks.sh` and `ci/unit-cycles.sh` on it, and pushes to `main` the
moves that pass. A move that fails a step stays out and turns the run red, and
GitHub emails the failure. A warning that a move stays out, such as an app
that does not build or nixpkgs held back, turns the run red too, except the
one that llm-agents waits for cache.numtide.com, which clears by itself. When `main` moves during the run, the run pushes
nothing and the next one tries again. Its run summary lists the moves and the
warnings. `gh workflow run update.yml` starts it now. It builds no host's
system, so a move that evaluates but fails to build reaches the hosts, which
keep their system and show "Update failed" ([Updater](nixos-rog.md#updater)).
Each host installs `main` within the hour after the push.

`move-inputs.sh` and `update-release-tags.sh` run `nix flake update`, and
`update-app.sh` runs `nix hash convert` for the Grok Bot package, npm and
`prefetch-npm-deps` through Nix for cf and openchamber-web, and a build for the
apps with a GitHub release source. Run those scripts in a
checkout on nixos-desktop or nixos-rog, which have Nix, `gh` and `jq`.
`update-app.sh antigravity-hub`, `update-app.sh openchamber` and
`update-app.sh impeccable` need no Nix. `scripts/prepare-update.sh` runs all
three scripts, and `devenv update` for `devenv.lock`
([Update by hand](#update-by-hand)).

Each script changes files in that checkout and commits nothing. Commit the
change and push it to `main` as [AGENTS.md](../AGENTS.md) describes, then
deploy as [deploy.md](deploy.md#deploy-a-change-on-main) describes.

## Update by hand

The `update` workflow runs these steps every 2 hours. Run them by hand when a move is
needed now, on nixos-desktop or nixos-rog, in a worktree on a branch from a
freshly fetched `origin/main`:

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
curl and jq. A move that stays out prints a `warning:` line on
stderr that names the cause, and the other moves go ahead. An optional fourth
argument names a file that gets those warnings without the `warning:` prefix;
`ci/update.sh` reads it, because Nix prints its own `warning:` lines on the
same stderr.

On nixos-desktop and nixos-rog, neither Nix nor the shell holds a GitHub
token, so a run soon hits GitHub's unauthenticated API limit. Nix then keeps an
input where it is with only an `HTTP error 403` warning, and `update-app.sh`
keeps an app. Run either mode with both tokens the `update` workflow passes,
Nix's access token and `GH_TOKEN`:
`GH_TOKEN="$(gh auth token)" NIX_CONFIG="access-tokens = github.com=$(gh auth token)"`.

To prove a change to the inputs mode on an input that moves, put back the
`flake.lock` of a commit whose root nixpkgs differs from `main`'s. A lock that
differs from `main` only in llm-agents moves nothing before `eval_error`,
because `move-inputs.sh` skips llm-agents and it moves later.
This prints each candidate and its root nixpkgs, `HEAD` last:

```sh
for c in $(git log --format=%h -n 6 -- flake.lock | sed 's/$/^/') HEAD; do
  printf '%s %s\n' "$c" "$(git show "${c}:flake.lock" | jq -r '.nodes[.nodes.root.inputs.nixpkgs].locked.rev[0:7]')"
done
git show <candidate>:flake.lock > flake.lock
```

Run the script under `bash -x` and check that the trace calls `eval_error`.
The changes file can stay empty, because the move can land on exactly
`main`'s lock and the file lists differences from `main`.

A package test that fails in the build of step 3 is a bug. Fix it in
`overlays/` before the push, as [Nixpkgs](../AGENTS.md#nixpkgs) describes. A
passing rerun does not clear it, because the test can fail again on the next
build of that package.

| Input | When it moves |
| --- | --- |
| llm-agents | Only when a cache holds its builds. See the paragraph below. |
| kwin-effects-glass, glass-style, hushmic, nixpkgs-spotify, spicetify-nix, tinted-vscode and warm-burnout | Never. Their `flake.nix` URLs pin a commit, so moving one is a hand edit. |

When the new llm-agents revision has a coding agent that cache.numtide.com does
not hold yet for the host's system, or the script cannot tell, llm-agents stays
where it is. So the laptop does not compile an agent at full load. The next
update tries again.

## The kernel

The hosts run the CachyOS kernel of
[nix-cachyos-kernel](https://github.com/xddxdd/nix-cachyos-kernel) from its
`release` branch. Upstream moves that branch only to a kernel its Hydra has
built and pushed to its cache, cache.lantian.pub (upstream's README, "How to use
kernels"). `nixosModules/kernel.nix` adds that cache as a substituter, so the
kernel moves with the other inputs, through `prepare-update.sh inputs` or
`nix flake update nix-cachyos-kernel`, and a host downloads it.

The cache holds a host's kernel only while the host builds it as upstream does:

- `nixosModules/kernel.nix` uses the input's `pinned` overlay, which builds the
  kernel with the input's own nixpkgs.
- `flake.nix` does not let the input follow our nixpkgs.

Each host compiles the modules it builds against the kernel: the NVIDIA open
module (`machines/nixos-rog/nvidia-driver.nix`), ryzen-smu, turbostat and
v4l2loopback on nixos-rog, and nct6687d on nixos-desktop. On 2026-10-30,
`scripts/build.sh` on nixos-desktop built the NVIDIA open module, ryzen-smu,
turbostat and nct6687d for kernel 7.3.0 in 155 s together.

`deploy.sh` builds on the target with the `nix.conf` the target runs, so a
host reads a new substituter only after it runs a system that lists it. Deploy
a substituter change to each host before the change that needs it.

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

`move-inputs.sh` never moves llm-agents, because it moves only once
cache.numtide.com holds its builds. It moves every input, or only the inputs it
names. `prepare-update.sh inputs` runs it.

A plain `nix flake update` moves every input without a cache check. A host may
then compile the llm-agents packages. To move one input by hand, use `nix flake update <input>`, or
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
