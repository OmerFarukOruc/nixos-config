# How the flake fits together

- [Inventory](#inventory)
- [Login sessions](#login-sessions)
- [Add a host, launcher, shell or kernel profile](#add-a-host-launcher-shell-or-kernel-profile)
- [Theme](#theme)
- [Secrets](#secrets)
- [Home Manager](#home-manager)
- [Failure popups](#failure-popups)
- [DPI bypass and the WARP proxy](#dpi-bypass-and-the-warp-proxy)
- [nixos-desktop case fans](#nixos-desktop-case-fans)

The flake builds `nixos-desktop`, `nixos-latitude`, `nixos-rog` and `devbox`.

## Inventory

Shared NixOS policy lives in `nixosModules/`. Active host files live in
`machines/<host>/`.

`nixosModules/default.nix` imports the modules every host uses, and it imports
`nixosModules/workstation.nix`, which lists the workstation modules. Each module
turns itself on from the machine record. It reads `kind`, `gpu` or a
`features.*` switch, or it asks the `sessions` helpers (the module argument that
`nixosModules/machine.nix` passes) which desktops and shells the machine offers.
A module that every host or every workstation wants goes in one of the two
import lists and gates its own config on the record. A module that only some
hosts want is imported from those hosts' files in `machines/<host>/`, so the
other hosts do not get it; the `imports` of each `machines/<host>/` file name
them. A third workstation that wants one of them adds that import line to its
own files.

A machine of kind `server` gets none of the workstation modules. Each of them
gates on `kind == "workstation"`, on a feature, on the machine's `gpu`
(`intel-graphics.nix` and `amd-graphics.nix`), or on the machine's sessions, and
the modules for graphical apps, the wallpaper and the failure popup skip a
machine with no session, and the fonts skip one with no graphical user.
`connectivity.nix` (NetworkManager, SSH and sudo) is workstation-only, so the schema rejects `features.remoteAccess` on a server.
`nixosModules/tailscale.nix` and `nixosModules/ssh.nix` (the settings every
sshd shares) serve every host, and `nixosModules/server-access.nix` adds a
server's Tailscale flags and SSH ([devbox](devbox.md#access)). `ci/server.nix` evaluates a
server record with no sessions, and `ci/checks.sh` fails when one of the pieces
it lists comes in, when the record's access or boot setup changes, when a
streamed desktop adds a piece it should not, when nixos-desktop or nixos-rog
loses the fallback copy of its EFI binary, or when the schema stops rejecting
one of the three records it rejects: `features.remoteAccess` on a server,
`biosDevice` with systemd-boot, and `features.streamedDesktop` on a
workstation ([Check before you deploy](deploy.md#check-before-you-deploy)).

A server has a desktop through `features.streamedDesktop`, not through a login
session: `nixosModules/streamed-desktop.nix` starts XFCE for each RDP login of
omer over the tailnet ([Streamed desktop](devbox.md#streamed-desktop)).
`features.remoteDesktop` stays the workstation's switch for Sunshine on its own
screen, and it still requires `remoteAccess`. The session list of such a server
stays empty, so the modules that ask `sessions.hasAnyDesktop` (the login screen,
Ghostty, the wallpaper, VS Code, the launchers) skip it. The modules that give a
graphical user fonts, a browser, its certificate database and the keyboard layout
ask `sessions.hasGraphicalUser`, which is true for a login session or a streamed
desktop. `ci/checks.sh` lists the pieces a server with a streamed desktop gets.

`nixosModules/bootloader.nix` sets `boot.loader.efi.canTouchEfiVariables` to true
as a default. A machine that boots through BIOS sets it to false, because its
firmware keeps no boot entries to write. Limine then installs its EFI binary at
the firmware fallback path only. With `biosDevice` in the record, Limine also
installs its BIOS stage on that disk, so one disk is laid out for either
firmware; devbox's VM test boots it through BIOS only.

`machines/inventory.nix` holds one value per machine for the typed
`oruc.machine` option that `nixosModules/machine.nix` declares. `schema.nix`
lists every field with its default and description. The fields a new host most
needs are `deployLogin` (the user `deploy.sh` logs in as; a server sets `root`),
`autoLogin` (the display manager logs the user in at boot) and
`theme.plasmaLook` (the Plasma look a login starts with, null without a Plasma
session). The `sessions` field is described in [Login sessions](#login-sessions).

The other files in `machines/` define what a record may hold:

- `schema.nix` declares each option, its default, and the checks that reject an
  invalid record. For example, only a workstation offers a desktop session.
- `selectors.nix` lists the valid launchers, shells and kernel profiles, and the
  desktops that each launcher and shell supports.
- `schemes.nix` maps each Base16 scheme name to its file, from the pinned
  tinted-theming input or `assets/schemes`.
- `sessions.nix` has the `sessions` helpers.
- `variants.nix` lists the Home Manager variants of a record: one per Plasma
  look ([Theme](#theme)).

Every session reads the same idle and touchpad settings. Plasma reads the idle
settings through powerdevil (`home-manager/modules/plasma-manager.nix`). It reads
the touchpad settings through a kcminputrc entry for the touchpad's device id,
which each Plasma host writes in its own `home.nix`
(`machines/nixos-rog/home.nix`). niri reads the touchpad section of
`/etc/niri/host.kdl` and one swayidle service (`home-manager/modules/idle.nix`)
under either shell. A machine with no battery uses only the AC idle values under
niri.

By default, on battery, the screen dims after 2 minutes and turns off after 5.
On AC it does neither. The screen never locks, and the machine never suspends.
The dim step touches only `/sys/class/backlight/*_b*`, which matches
`amdgpu_bl*` and `intel_backlight` and skips `nvidia_0`. On a hybrid laptop
`nvidia_0` comes first, and touching it wakes the RTX 4070.

## Login sessions

nixos-rog offers Plasma, niri with Noctalia and niri with DMS from the same
display manager. So a machine record holds a list of login sessions. Each
session is a desktop with its shell, and the first session is the default.

The list is one record field, with no per-desktop host overrides, because every
consumer (login, desktop, theme, launchers, shells) must agree on which
desktops exist.

These rules follow from the list:

- **Session units.** Every session reaches `graphical-session.target`, so a
  user service that belongs to one desktop binds to that desktop's own unit
  instead. Units this repository writes for Plasma name
  `plasma-workspace.target` directly. Units that Home Manager modules define
  for niri register in `oruc.sessionServices`, or in `oruc.shellServices` when
  one shell owns them. On a machine with more than one session, the
  registration rebinds them to `niri.service`.
- **One session per shell.** A desktop with more than one shell gets one
  display manager session per shell, named `<desktop>-<shell>`, in place of its
  own. The session's launcher sets `ORUC_SHELL`, and each shell's services
  start only when it matches. Every niri shell's launcher sets `NIRI_CONFIG` to
  `/etc/niri/<session>.kdl`, which includes `/etc/niri/config.kdl`
  (`niri/config.kdl`, the system-wide niri config) and then the shell's binds.
  The file is `niri-<shell>.kdl` when the machine has several niri shells and
  `niri.kdl` when it has one (`sessionName` in `machines/sessions.nix`). Because
  `NIRI_CONFIG` is set, niri does not read `~/.config/niri/config.kdl`.
  A niri session that is already open misses a deploy that changes the
  launcher. [Deploy](deploy.md#deploy) says how to tell and what to do.
- **Plasma owns the shared look.** With Plasma present, Plasma owns
  `kdeglobals`, the GTK settings and the cursor, and the niri session inherits
  them. A niri-only machine keeps the files that Home Manager writes. The GTK
  colors and the GTK 3 theme name are the exceptions. Plasma's `gtk.css` is a
  regular file that kded rewrites, so Home Manager links `oruc-colors.css`
  beside it and an activation step adds the `@import` line to `gtk.css`.
  `oruc-polarity` sets the GTK 3 theme to adw-gtk3 (the dark one for a dark
  scheme) in `settings.ini` and in dconf, but only while the theme is unset or
  already adw-gtk3, so a theme chosen in System Settings stays.
- **Blur rules.** Blur shows only through translucent pixels, so the
  `window-rule` and `layer-rule` blocks in `niri/config.kdl` are an allow-list of
  surfaces that are translucent. niri enables xray blur with any background
  effect, which blurs the wallpaper once and reuses it. The DMS dock is not on
  the list, because DMS requests blur for the dock's own shape. A rule that
  matched the dock's full-width surface painted a dark strip about 90 px tall
  over the bottom of the windows (observed 2026-09-21).

## Add a host, launcher, shell or kernel profile

- **A host.** Add a record to `rawMachines` in `machines/inventory.nix`. A record
  alone stays inert. To build the host, add a
  `nixosConfigurations.<name>` block in the same file, with `hostModules` that
  name `machines/<name>/configuration.nix` and `hardware-configuration.nix`.
  The host's `configuration.nix` imports each opt-in module it wants
  ([Inventory](#inventory)).
- **A launcher.** Add it to `launcherSpecs` in `machines/selectors.nix` and
  create `home-manager/modules/launchers/<name>.nix`. `launchers/default.nix`
  imports a file for each name in `selectors.nix`.
- **A shell.** Add it to `shellSpecs` in `machines/selectors.nix` and create
  `home-manager/modules/shells/<name>.nix`. A niri shell also needs
  `niri/shells/<name>.kdl` with its binds, because niri treats a missing include
  as an error. Those binds include `Mod+X` and `XF86PowerOff` (the power key),
  which open the shell's power menu.
- **A kernel profile.** Add it to `kernelSpecs` in `machines/selectors.nix`. For
  a CachyOS profile, set its `package` to
  `[ "cachyosKernels" "linuxPackages-cachyos-<variant>" ]` with a variant that
  upstream's cache holds; [nix-cachyos-kernel's README](https://github.com/xddxdd/nix-cachyos-kernel#which-kernel-versions-are-provided)
  marks the variants it does not cache ([The kernel](updates.md#the-kernel)).
  `nixosModules/kernel.nix` adds the CachyOS overlay and cache.lantian.pub only
  to a host whose profile's package starts with `cachyosKernels`.

## Theme

`nixosModules/theme-module.nix` sets the read-only `oruc.theme` values of a
Base16 scheme. `nixosModules/theme-values.nix` gives whether the scheme is
light, the cursor and GTK theme that follow that variant, the icons
(`nixosModules/icon-theme.nix`), and the ANSI slots; the module adds the fixed
font families. The theme pack calls `theme-values.nix`
for every scheme.

NixOS and Home Manager each import that module with their own scheme:

- NixOS (`nixosModules/theme.nix`) uses `theme.scheme` from the machine record.
  niri reads it until a Home Manager activation writes its colour file
  (below). The console, the login screen and the Limine boot menu start from
  it and then follow the stored scheme (below).
- Home Manager (`home-manager/modules/scheme.nix`) uses `theme.scheme` too, so
  its `config.scheme` and `config.oruc.theme` hold the record scheme. Only the
  pack renderers below follow `theme`; a file that a module builds from
  `config.scheme` directly keeps the record scheme.

The wallpaper is the file in `assets/wallpapers/<host>` or `assets/wallpapers`
named after the scheme. A scheme without one gets the matching `default.png`
recolored to the scheme's 16 colors by `lutgen apply -R -P`, which preserves
luminosity so `#000000` stays black. In the session, `oruc-wallpaper-path`
(`home-manager/modules/wallpaper.nix`) prints the wallpaper of the scheme that
`theme/current` points at: the scheme's own file, or a PNG it renders from the
pack's `palette` fact into `~/.cache/oruc/wallpapers/<scheme>-<key>.png`. The
key hashes the palette, the `default.png` path and lutgen, so a changed input
renders a new file. One render took 0.05 to 0.07 s in 3 runs on nixos-rog
(2026-10-31). Plasma, Noctalia and DMS take the wallpaper from it, so it
follows any scheme. On Plasma, plasma-manager's startup script `oruc-wallpaper`
sets it at each login after the panel script, which deletes the desktop's
wallpaper when it rebuilds the panels, and the reload `wallpaper` sets it at
each switch.

Each Plasma look is a Home Manager variant (`machines/variants.nix`). The
row of `theme.plasmaLook` is the Home Manager generation, and each other look
is a specialisation (`home-manager/modules/variants.nix`), which `plasma-look`
activates (`nixosModules/hm-variants.nix`). A host without Plasma has no
variants. The shell commands read the finished rows and do not rebuild them.
`theme <scheme>` activates no variant: it stores the scheme, points `current`
at it in the pack and runs the reloads, so any scheme of the pack switches in
the same way. `plasma-look <look>` stores the look and activates its variant
([Switch the scheme](workstations.md#switch-the-scheme)). Each deploy and each
boot activates the default look first, so the Home Manager service then runs
`theme --reapply`, which activates the stored look and runs the reloads.

NixOS installs only the generation's own packages, so a specialisation
cannot change one. A color therefore reaches an app through a file that Home
Manager writes, never through a package built with it. Neovim, VS Code and fzf
read their colors from files for this reason. KDE apps take the scheme's icon
theme from `~/.config/kdeglobals` in the pack.

The pointer cursor is Bibata Modern recoloured per scheme: base05 fills it,
base00 outlines it and base0D draws the busy circle. The reload
`pointer-cursor` starts `oruc-pointer-cursor` (`appearance.nix`) through
`systemd-run`, which renders the theme named by the pack's fact
`pointer-cursor`, `Oruc-Cursor-<slug>-<hash>`, into `~/.local/share/icons`
with `pkgs/oruc-cursor.nix` the first time it is used. The hash covers the
three colours, the builder file and the versions of Bibata, resvg and
clickgen, so a changed palette or builder gets a new theme. On a host with
niri it writes the name to `~/.config/niri/oruc-cursor.kdl`, which
`niri/config.kdl` includes after the record's cursor, on every run, so a niri
login after a switch made in Plasma shows it too. It then applies the theme
with `plasma-apply-cursortheme` in a Plasma session, or through
`oruc-gtk-polarity` outside Plasma. A build took 7 s on nixos-rog
(2026-11-01) and holds 28 MB, so the script keeps the two most recently used
themes and removes older ones. The reload exits at once while
`graphical-session.target` is inactive, as after a deploy at boot, and a login
applies the built theme. `oruc-polarity` and `oruc-gtk-polarity` apply the
recoloured theme when it is built, else the fact `cursor`, so a login keeps
it. A failed build prints `theme: cursor build failed` to the user journal and
applies the fact `cursor`. Outside a Plasma session, the reload `polarity`
runs `oruc-gtk-polarity` (`home-manager/modules/appearance.nix`), which writes
the GTK theme, cursor, colour preference and icon theme of the variant to
dconf from the pack's facts `gtk`, `pointer-cursor` or `cursor`, `polarity`
and `icons`. It keeps a GTK theme picked by hand
outside `adw-gtk3` and `adw-gtk3-dark`, and an icon theme outside the
`replaceable` names of `nixosModules/icon-theme.nix`. Home Manager's GTK module
writes the record's values to the same dconf keys at each activation, and
`theme --reapply` then runs the reload again.
`nixosModules/hm-variants.nix` fails the evaluation when a variant's packages
differ from the generation's, and names them.

The apps that read their colours from a file follow any scheme without a
variant, through the theme pack (`home-manager/modules/theme-pack.nix`). Each
module adds a renderer to `oruc.themeFiles`, keyed by the file's path under
`$HOME`, and the pack, a store path in the generation, holds each renderer's
file for each scheme as `<scheme>/<path>`, with a `slugs` file that lists the
schemes and, per scheme, `.oruc/polarity` (dark or light) and the scheme's YAML
as `.oruc/source.yaml`. Each such file in `$HOME` links to
`~/.local/state/oruc/theme/current/<path>`, and `current` links to
`pack/<scheme>`. `theme/pack` links to the generation's pack and is a GC root.
`oruc-theme-pointer` owns these links and holds `theme/lock` while it changes
them. `theme` and `plasma-look` hold `switch.lock` for a whole switch, so two
runs cannot leave the stored look, the activated look and the reloads apart.
`plasma-look` and `theme --reapply` refuse to activate a look once a deploy
replaced the system they came from. Each Home Manager activation roots its own pack, so a rollback brings
the old pack back, and points `current` at the stored scheme
(`~/.local/state/oruc/scheme`), or at the record scheme when the pack lacks
it. `theme <scheme>` replaces the stored scheme through a rename, which is the
one step that commits a switch, points `current` at it, and then runs
`oruc.variantReloads` so Ghostty, tmux, Neovim, VS Code, Noctalia and DMS load
the new files. A reload exits 0 when its app does not run. `theme --reapply`
runs the reloads too, and `noctalia.service` and `dms.service` run their reload
script when they start, because each shell keeps its dark or light mode in its
own state, which no Home Manager file sets. For DMS that state cannot hold the
mode at all: `home-manager/modules/shells/dms.nix` sets `settings` and `session`,
so Home Manager links `~/.config/dms/settings.json` and
`~/.local/state/dms/session.json` into the store, read-only. DMS then stores no
mode, wallpaper or pinned app, and the start-time script sets the mode again
each time. Claude Code reloads
its theme when the file is replaced, but not when a link on its path changes
target, so its theme file is listed in `oruc.themeCopies`: the pointer writes
it as a regular file and replaces it through a rename each time it moves
`current`. DMS and vicinae watch their theme file in the same way. The Plasma
splash `Splash.qml` is a copy too, because KPackage refuses a file whose real
path lies outside the look-and-feel folder ("Path traversal attempt detected"
in the journal), which left the splash blank while Home Manager linked it into
the store. niri reads the record's colours from `/etc/niri/theme.kdl` and then
`~/.config/niri/oruc-theme.kdl` from the pack, an `optional` include that it
watches, so the later file wins at once. kVitals takes its text, warning and
critical colours from the KDE colours: `pkgs/kvitals.nix` points its threshold
colours at `Kirigami.Theme`. A renderer runs for every scheme, so it must give a valid file for
each; the Markdown viewer's code colours move toward black or white when the
scheme's foreground cannot reach 4.5:1 on the code background. Specialisations
reuse the generation's pack, and root's Home Manager and the servers get a
pack with the record scheme alone. `oruc.themeFacts` adds a value per
scheme to the pack as `.oruc/<name>`, such as the Glass glow colour.
`claude-code-theme.nix` writes `.oruc/statusline`, the segment backgrounds,
text colours and usage colours that dotfiles' `desktop/claude-code/statusline.sh`
reads; when the fact is missing or lacks a key, that script keeps its fixed
colour for it.

The console, the login screen and the boot menu run outside the user session,
so `nixosModules/theme-root.nix` builds a system pack with each scheme's
console palette (`vtrgb`), login screen colours (`sddm.conf.user`) and, on a
Limine host, boot menu colours (`limine`), on hosts with a desktop. `theme <scheme>` passes the scheme on stdin to `oruc-theme-root`
through `sudo -n`, which a sudo rule allows for the record's user alone. The
helper stores it in `/var/lib/oruc/theme/scheme`, runs `setvtrgb`, and writes
`/var/lib/oruc/theme/sddm/jake_the_dog.conf.user`, the file the login theme's
`.conf.user` link in the store points at; SDDM reads it at each greeter start.
At boot, before the display manager, and at each switch,
`oruc-theme-root.service` runs `oruc-theme-root --apply`, which applies the
stored scheme, or the record's when none is stored. The helper holds
`/var/lib/oruc/theme/lock` while it reads, stores and applies, so a switch and
`theme` cannot leave the stored scheme and the applied colours apart. The unit
always exits 0, so a failure never rolls back a deploy; it writes
`/var/lib/oruc/theme/apply-failed` instead. `theme` with no argument prints
the console and login screen scheme next to the user's, and a line for this
marker and for a failed `theme --reapply`, on every workstation;
`scripts/verify-nixos-rog.sh` also checks both markers.
A light scheme's `sddm.conf.user` holds the record's colours, because the
login form is drawn at 30 % opacity over a dark video. `theme --reapply` does
not call the helper.

On a Limine host the helper also rewrites the ten colour lines of
`/boot/limine/limine.conf`, the ones `limine-install.py` writes from
`boot.loader.limine.style`. It requires each key exactly once and every other
line unchanged, else it leaves the file as it was, and it replaces the file
through a rename and syncs it. Each bootloader install writes the record's
colours, so `boot.loader.limine.extraInstallCommands` runs
`oruc-theme-root --limine`, which writes the stored scheme's colours again and
never fails the install. `theme` runs `oruc-theme-root --limine` as its last
step, after it released its own lock, so a switch that waits for `theme
--reapply` can finish first. `--limine` takes
`/run/nixos/switch-to-configuration.lock` for up to 60 s, so it never edits the
file during a switch; a switch that starts meanwhile exits with "Could not
acquire lock" and the next one succeeds. It skips that lock when `NIXOS_ACTION`
is set, because then a switch that holds it runs the install. With
`boot.loader.limine.enrollConfig` on, Limine checks the file against a hash in
its binary, so the helper then leaves the boot menu alone.

On Plasma, `theme` then runs `oruc-plasma-live`
(`home-manager/modules/plasma-looks/default.nix`), which changes the running
session:

- **KDE colours.** The pack holds the opaque `OrucBase16.colors` of Klassy and
  the translucent `OrucBase16Glass.colors` of Glass under
  `.local/share/oruc/kde/`. `plasma-apply-colorscheme` does nothing for the
  scheme that is already selected, so `oruc-kde-colors` copies the file to the
  `A` or `B` name that `kdeglobals` does not hold, such as `OrucBase16GlassB`,
  and applies that copy. KDE apps repaint, and kded writes the GTK colours of
  the new scheme. When the copy that runs already matches the pack's file, it
  changes nothing.
- **Dark or light set.** `oruc-polarity` (`home-manager/modules/appearance.nix`)
  gives the session the cursor, GTK 3 theme name and dconf `color-scheme` of
  the scheme's variant, which the pack holds as the facts `gtk` and
  `polarity`, and the scheme's recoloured cursor once built, else the fact
  `cursor`, but keeps a GTK theme picked in System Settings. It does this at
  each login and when the variant changed, and records the variant in
  `~/.local/state/oruc/theme/polarity`. Otherwise it sets `color-scheme` to
  `default` and back, so GTK 4 apps load `oruc-colors.css` again. On every run
  it also sets the scheme's icon theme, the fact `icons`, when the session's
  differs and is unset or one of the `replaceable` names in
  `nixosModules/icon-theme.nix`.
- **Plasma style.** `looks` in `plasma-looks/default.nix` names each look's
  colour scheme and Plasma style: `oruc-glass`, or `klassy-dark` and
  `klassy-light` by the variant. plasma-manager runs its theme script only when
  the script's text changed since its last run, so a switch back to a look
  would skip it; `oruc-plasma-live` sets the style instead.
- **Glass glow.** With the Glass colours, it writes the pack's `.oruc/glow` to
  `kwinrc` and reconfigures the effect when the colour differs.

`theme` takes the look from the KDE colour scheme that runs, so a
`plasma-look` that waits for the next login does not change the running
session's look. The login unit `oruc-plasma-colors` runs the same steps with
`--login` and the generation's look once per Plasma login, so a new login shows
the stored scheme and look; `oruc-niri-colors` applies the opaque colours once
per niri login on a host that also has Plasma. A deploy or `plasma-look` never
changes the KDE colours of a running session, because a live colour scheme
change crashed Discord on 2026-10-16; `theme` does, because switching the
scheme asks for it.

`machines/scheme-parser.nix` reads each scheme file line by line, because
base16.nix's YAML parser fails on 14 tinted-theming files, such as `dracula`
and `ascendancy`. It reads only `name`, `author`, `variant` and the 16 palette
colours, and fails with the file and key on a value it cannot read, such as a
backslash escape, and on anything else in the palette. The `scheme-catalogue`
flake check, which `ci/checks.sh` builds, compares its result for every file
with `yq`'s.

`assets/schemes` holds the schemes that tinted-theming lacks. The
`warm-burnout-dark` and `warm-burnout-light` schemes there copy the palette of
the `warm-burnout` input's pinned commit (github:felipefdl/warm-burnout v1.8.0,
`nvim/lua/warm-burnout/palette.lua`). Some slots are derived, not copied:

- In both schemes, `base06` lies halfway between `base05` and `base07`.
- In `warm-burnout-dark.yaml`, `base07` comes from the theme's Home Assistant
  version, `base02` is the translucent selection and `base03` the gutter color,
  each drawn over the background.
- In `warm-burnout-light.yaml`, `base02` is the VS Code theme's translucent
  selection drawn over the background.

With either of them, VS Code and Neovim use that input's own theme in place of
the Base16 one; `home-manager/modules/theme.nix` installs both, and
`theme.warmBurnout` tells the renderers which schemes they are. To move the
input, change its commit in `flake.nix`, compare the new palette
(`nvim/lua/warm-burnout/palette.lua`) with the two scheme files, and check that
the VS Code theme labels in `home-manager/modules/vscode.nix` and the Neovim
color scheme names in `theme.nix` still match.

VS Code follows any scheme without a restart. `vscode.nix` installs one
extension, `oruc.base16-theme`, whose themes `Oruc Base16 Dark` and
`Oruc Base16 Light` both read `~/.config/oruc/vscode-theme.json`, a file in
`oruc.themeCopies` that VS Code watches. Its renderer fills the
`tinted-vscode` input's pinned `base16` template and changes three kinds of
text color, with the functions in `nixosModules/contrast.nix`:

- Text on an accent background (`base08` to `base0F`), such as
  `button.foreground` on `button.background`, takes `theme.readableOn` of that
  background: `base00` or `base07`, whichever has more contrast, when it
  reaches 4.5:1, else black or white. The hover backgrounds of those buttons
  and status bar items move 15 % away from that text, so it stays readable on
  hover.
- Text on `base05` takes the normal text color: `base05`, or, when `base05`
  stays under 4.5:1 on `base00` or `base01` (the editor and side bar
  backgrounds), `base05` moved toward black or white until it reaches 4.5:1.
- Muted text on `base02` to `base04`, such as descriptions, placeholders, line
  numbers and comments, takes a faint level (`base02`, `base03`) or a dim level
  (`base04`), each moved toward `base05` just far enough to reach 4.5:1. Faint
  stays dimmer than dim, and dim dimmer than normal text; in the schemes whose
  normal text is itself close to 4.5:1, the levels fall together. Whitespace
  marks, rulers and the comment gutter keep their faint scheme color.

When no color reaches 4.5:1 on both backgrounds, as in brogrammer, whose
`base01` is bright red, only the editor background counts. The facts
`.oruc/vscode-pairs`, `.oruc/vscode-text` and `.oruc/vscode-label` in the pack
list the keys the renderer changed and the color theme VS Code shows, and
`scripts/check-theme.sh --contrast` checks them in every scheme that uses this
theme. The Warm Burnout schemes use their own theme, so the check skips them.
The same run checks the `statusline` fact of every scheme: each segment
background is the scheme's slot, and each text and usage colour reaches 4.5:1
on it. GTK's accent, destructive, success, warning and error colours, KDE's
selection, tmux's current window, Noctalia's and DMS's accents and the login
screen's button and highlight draw their text in `theme.textOn` of the
fill they sit on, and the same run checks that it reaches 4.5:1 in every scheme.
It also checks each KDE colour group's text on its own background, the Window
text on the Button background and the Button text on the Window background at
4.5:1, in both the opaque and the Glass scheme. The `theme-contrast` flake
check, which `ci/checks.sh` builds before each push, runs the same checks
(`scripts/lib/theme-contrast.py`) on nixos-rog's theme pack.

The pack file `~/.config/oruc/vscode-colors.json` holds `workbench.colorTheme`,
`window.systemColorTheme` and `workbench.colorCustomizations`, and
`oruc-code-colors`, Home Manager's own writer for a mutable `settings.json`,
merges it into that file at each activation and each switch; it leaves a
`settings.json` that does not parse, or that VS Code changed meanwhile,
unchanged. `vscode.nix` also rewrites the fixed colors in the vibrancy input's
stylesheet with the scheme's, in the pack file
`~/.config/oruc/vscode-vibrancy.json`, which VS Code reads at its start.
Evaluation fails when that stylesheet no longer holds a color that `vscode.nix`
rewrites.

`home-manager/modules/agent-theme.nix` gives Codex a tmTheme
(`~/.codex/themes/oruc.tmTheme`) and opencode and pi a theme JSON each, all
named `oruc`. Their `oruc.appSettings` entries set `tui.theme`, the ChatGPT
app's chrome and code theme in `~/.codex/config.toml` (from the pack's
`codex-settings` fact), opencode's `cli.json` and pi's `settings.json` to that
theme, and opencode's entry sends its terminal UI `SIGUSR2`, which makes it
read its themes again. Ghostty's entry in `applications.nix` sets no file and
only sends `SIGUSR2`, which makes each Ghostty window load its configuration
again, also one started by name from a shell or from an older store path.

`home-manager/modules/app-settings.nix` turns `oruc.appSettings` into one
reload per app, each a run of `oruc-app-settings <app>`, which merges fixed
values or a fact's JSON into the app's JSON, TOML, INI or `user.js` file, or
copies a pack file. A path may hold `{vault}`, each vault in Obsidian's vault
list, or `{profile}`, the default profile of a Mozilla `profiles.ini`. An app
that writes its settings file itself would overwrite the change, so the tool
leaves that file alone while the app runs and prints `theme: <app> runs`;
an entry marked `live` is a file the app only reads, written at once. It finds
an app by its executable's package name and path in any store path, or a
command line pattern for one started by an interpreter, so a process still
running from an older store path counts too. A Codex `app-server` or opencode
`serve` process and its children do not count, because such a background
server writes the file only for a client. A file with a `lock` waits only while
that Chromium `SingletonLock` names another host or a running process of the
app, so each browser profile waits on its own lock, a closed Brave (WARP)
profile changes while Brave runs, and a lock left by a crash holds nothing. The
tool compares parsed values, so an app that writes the same
settings in its own layout leaves nothing to change. It reports a file it
cannot parse and still writes the others. `oruc-app-settings --check` exits 1
when a file's values differ from what the stored scheme sets. `settings_file.py` holds the TOML merge and the
write through a temporary file that keeps the file's mode, for this tool and
herdr's.

`home-manager/modules/app-themes.nix`, which the personal profile imports,
themes the desktop apps through the same tool. Konsole's default profile
`Oruc` selects the pack's `OrucBase16` colour scheme. Thunderbird's default
profile gets the pack's stylesheet as `chrome/userChrome.css`, with the
`user.js` preference that makes it load it; mail content keeps its own
colours. Obsidian gets the pack's snippet `oruc-scheme.css` in each vault, and
the vault's `appearance.json` enables it and picks Obsidian's dark or light
base to match the scheme. SourceGit's `preference.json` names the pack's
`sourcegit-theme.json` in `ThemeOverrides` with its dark or light `Theme`,
and jadx's `gui.json` takes the
FlatLaf look of the scheme's dark or light variant; the switch creates neither
file nor OBS's `user.ini`, so each app writes its own at its first start. The
Cursor editor gets `vscode.nix`'s extension in `~/.cursor/extensions` and its
`settings.json` selects `Oruc Base16 Dark` or `Light`. On nixos-rog, OBS gets
two pack themes, `OrucDark.ovt` extending Yami and `OrucLight.ovt` extending
Yami Light, whose accents are moved toward black or white until OBS's text
reaches 4.5:1 on them, and `user.ini` selects the one of the scheme's variant with
`AutoReload=true`, so OBS repaints when the switch replaces the file. OBS reads
the theme list and the `dark` flag only at start, so a switch between a dark
and a light scheme changes its icons at its next start.

`home-manager/modules/chat-themes.nix`, which the workstation profile imports,
installs Vesktop in place of the Discord app; Vesktop is a Discord client that
loads Vencord themes. Its pack theme
`~/.config/vesktop/themes/oruc.css` is Stylix's Discord theme
(`vesktop-colors.nix`, MIT) followed by a block that sets Discord's text
variables from the scheme's text roles, whatever Discord's own dark or light
setting is, and its accent fills to the scheme's accent moved toward black or
white until that text reaches 4.5:1 on them (`contrast.nix` `fillBehind`, which
OBS's accents use too). Vencord's `enabledThemes` lists it. Vencord watches the
folder, so Vesktop repaints at once. The same module renders Telegram's palette
`~/.config/oruc/oruc.tdesktop-palette` from `telegram-palette.txt`, which gives
each colour key of Telegram's default palette a Base16 slot, a 15 % tint of an
accent into base00 (`tint:`), the readable text on an accent (`on:`), an
accent moved toward black or white until that text reads on it (`fill:`), or
Telegram's own colour for its always-dark media viewer, call and toast screens.
Telegram watches a palette it loaded from a file, so it repaints at each
switch once it has loaded this one.

`home-manager/modules/browser-themes.nix` gives Firefox the Pywalfox add-on, as
a policy that installs it, and its native host. The reload `pywalfox` writes
`~/.cache/wal/colors.json` from the pack's `pywal-colors` fact and
`oruc-wallpaper-path`, sets Pywalfox's dark or light mode and tells a running
Firefox to read the colours again. Brave, Brave (WARP) and Chromium follow the
desktop's colours, because their `Preferences` set
`extensions.theme.system_theme` to Qt (2) on a host with Plasma, whose KDE
colours they then follow at once, and to GTK (1) elsewhere, whose colours
apply at their next start; `oruc-app-settings` writes it, with an empty
`extensions.theme.id`, which Chromium requires for that mode, while the
browser is closed. In Qt mode Brave Origin 1.98 paints the tab strip with
the `[WM]` `inactiveBackground` (base00), the toolbar and active tab with the
Button background, and the active tab title and toolbar icons with the Window
text. `plasma-looks/kde-color-scheme.nix` therefore mixes base00 toward base05
until the Button background reaches 1.3:1 against base00 (`contrast.nix`
`raisedSurface`; 1.3:1 is Catppuccin Mocha's surface0, which Catppuccin's own
KDE scheme uses for buttons). Each KDE colour group lifts its text to 4.5:1 on
its own background with `legibleOn`, the Window text also on the Button
background and the Button text also on the Window background. `raisedSurface`
fails the evaluation when base05 cannot reach 1.3:1 against the surface below.
With base01 as the Button background, Mocha's active tab differed from the tab
strip by 1.07:1. `spicetify.nix` builds Spotify with Spicetify and links its
`Apps/xpui/colors.css` to the pack's `spicetify-colors.css` fact through the
theme pointer, so Spotify takes the stored scheme at its next start.

The ChatGPT app only offers its built-in code themes, listed in
`codex-code-themes.json` from its 26.1027.30824 bundle. The `codex-settings` fact
names the one a scheme takes: the one its name matches, such as `catppuccin`
for the Catppuccin schemes, else the variant of its dark or light kind
nearest by Oklab distance (`contrast.nix`) over background, text and accent,
weighted .55, .27 and .18. pi's theme comes only on hosts that set
`oruc.piTheme`, which `agent-cli.nix` does. grok, gum and the usage cards and
account list of `pkgs/claude-tools` draw with the terminal's 16 colours:
dotfiles' grok config selects its `terminal` theme, `agent-theme.nix` points
gum's colour variables at ANSI slots, and `terminal.py` and `picker.py` name
ANSI codes.

`theme.plasmaLook` names the default Plasma look, and a machine with no Plasma session leaves it null. `plasma-look` activates
another look at run time, with the same variants
([Plasma looks](nixos-rog.md#plasma-looks)).

`scripts/check-theme-drift.sh` runs inside `nix fmt` and fails on a fixed color
in a tracked file: `#RRGGBB`, `#RRGGBBAA` (and `#RGB` in CSS), or a number
inside `rgb(`, `rgba(`, `hsl(`, `hsla(`, `oklch(` or `oklab(`, or a 24-bit
terminal color code (`38;2;R;G;B`, `48;2;R;G;B`) or a 256-color one outside the
16 ANSI slots (`38;5;N`, `48;5;N` with N from 16). `#000000` and
`#00000000` pass, because black and full transparency carry no hue. A line that
holds `theme-drift-ok: <reason>` passes. A file listed in
`scripts/theme-drift-allow.txt` (`path-or-glob`, a tab, a reason) passes, and
the check fails when an entry matches no tracked file, so the list cannot go
stale. It does not read Markdown, lock files or `assets/`. It cannot see a hex string without `#`, a decimal triple outside a terminal color code, a color name
or a default inside a package, so a new package or module whose UI has such
colors writes them from an `oruc.themeFiles` renderer, or lands in the list
below with its reason.

These stay fixed on purpose, and the check does not cover them:

- Web pages and Electron app interiors follow only the dark or light variant,
  through the desktop portal.
- niri's hotkey overlay, screenshot UI and error banner.
- The icons other than folders. `nixosModules/icon-theme.nix` picks Gruvbox
  Plus for a gruvbox scheme, whose folders already match, and for every other
  scheme `Papirus-Oruc-<colour>-<Dark|Light>` from
  `nixosModules/papirus-folders.nix`: a theme that inherits Papirus-Dark or
  Papirus-Light and links its folder icons to Papirus's own folders in one of
  its 25 colours, the one nearest to base0D in OKLab with lightness counted at
  a quarter, because the folder icons keep their own shade. It also installs Fluent, MoreWaita and Colloid (orange accent,
  default and Gruvbox folders) to pick by hand in System Settings. On Plasma a
  theme picked there stays through `theme` switches and logins, until System
  Settings selects a Papirus, Papirus-Oruc, Gruvbox Plus, Breeze or Breeze
  Dark theme again. Colloid's
  Catppuccin set is left out, because its orange folders use the Gruvbox
  orange (`#fe8019`) in Colloid's `install.sh`.
- The Breeze desktop theme SVGs (their colors come from kdeglobals at run time)
  and the Glass Qt style.
- The print stylesheet of the Markdown viewer.
- The keyboard's Aura color and nixos-desktop's case lights follow the
  machine record's scheme from boot until the login, because asusd reads it
  from a system file (`machines/nixos-rog/asus.nix`) and `openrgb-boot`
  applies a fixed profile. After the login, `oruc-keyboard-light`
  (`home-manager/modules/keyboard-light.nix`) sets them to the stored scheme's
  base09, and `theme` restarts that unit at each switch while a graphical
  session runs. Before the login the reload does nothing, so the boot-time
  `theme --reapply` leaves the record's colour.
- Brave on other devices keeps its synced theme colour; on these PCs Brave
  draws with the desktop's Qt or GTK colours instead. `nixosModules/brave.nix` writes Brave's
  settings as policies, which Brave Origin reads from `/etc/brave/policies`. The
  recommended policies set the values a new profile starts with, and the
  settings page can still change them. Notification permissions and the theme
  color are managed-only policies, and Brave Sync carries them, so they stay
  in the profile. The one managed policy, `IdleDetectionAllowedForUrls`, lets
  Teams use the Idle Detection API, a permission that does not sync.
- The ChatGPT app's code view takes the nearest of its built-in code themes,
  so its syntax colors are the built-in theme's, not the scheme's.

## Secrets

`.sops.yaml` lists the recipients of the encrypted files under `secrets/`. Omer
edits them with the SSH key he shares across his devices,
`~/.ssh/id_ed25519_omer`. Each host decrypts its own file with the age key
derived from its SSH host key (`ssh-to-age` on
`/etc/ssh/ssh_host_ed25519_key.pub`). [Secrets](nixos-rog.md#secrets) says how
to edit a file.

## Home Manager

`nixosModules/home-manager.nix` integrates Home Manager and loads
`home-manager/common.nix`. A host adds its own layer from
`machines/<host>/home.nix`. Shared app sets are in `home-manager/profiles/`:
`workstation.nix` for every workstation, and `personal.nix` for the machines
Omer works at every day, with GPU tools that follow the machine record. Units a
host can share, such as desktop-sync, are in `home-manager/modules/`.

## Failure popups

`nixosModules/monitoring.nix` owns the option `oruc.failurePopupUnits`, a list
of system service names (without `.service`). Each listed service gets
`onFailure = [ "notify-failure@%p.service" ]` on a machine with a login session,
and `notify-failure@` sends the popup through systembus-notify. A server shows
no popup, and the list has no effect there. An assertion in the same file fails
the build when a listed service has no `ExecStart=` or script on that machine.

The rule is that every long-running or timer-run system service that this
repository defines on a desktop host is listed, unless it is on this list of
exceptions. The module that defines a service lists it next to the definition,
as `fans.nix` does for `case-fans` and `via-devbox.nix` for
`tailscaled-via-devbox`. No check finds a service that is missing from both
lists, so a new service needs that line by hand.

- `nixos-upgrade` has its own handler, `nixos-upgrade-failed`, which records the
  failed revision and shows an "Update failed" popup with its own text
  (`nixosModules/auto-upgrade.nix`).
- `openrgb-boot` is a oneshot that sets the case lights at boot and runs again
  at the next boot.
- `oruc-theme-root` is a oneshot that reports a failed step in its own journal
  and in `apply-failed` in its state folder, and the next boot runs it again.
- `envfs-reap` is a oneshot ordered before the `/usr/bin` mount, so a failure
  shows as a failed mount in the switch.
- `tailscaled-set` is a oneshot that follows `tailscaled`.
- `via-devbox-netns` is a oneshot that makes the network namespace, and
  `tailscaled-via-devbox` fails with it.

A new service adds its name where its neighbours are listed. A service that
needs no popup gets a line with its reason in the list of exceptions.

## DPI bypass and the WARP proxy

`nixos-desktop` and `nixos-rog` carry two ways to reach Discord when the line
blocks it. zapret2 (`nixosModules/zapret2.nix`, the hosts set
`services.zapret2.firewall.interfaces`) comes first, and the Cloudflare WARP
proxy (`nixosModules/warp.nix`) is the fallback for the Vesktop and Brave
launchers in `home-manager/modules/warp-launchers.nix`. The commands below ran
on nixos-rog on 2026-11-02 and only read state; nixos-desktop runs the same
modules with its own uplink.

**zapret2.** `nfqws2@default.service` rewrites the first packets of outgoing HTTP, TLS
and QUIC connections so the DPI on the line cannot match them. The firewall
rules (`sudo nft list table inet zapret2`) queue the first 16 packets of each
connection, in both directions, to `nfqws2` on the named uplink only: `wlp99s0`
on nixos-rog and `enp14s0` on nixos-desktop. Traffic on any other interface, and
connections to private addresses, pass untouched. The queue number and the
flags of each profile show in `systemctl cat nfqws2@default`.

The service runs three profiles. `http` and `tls` start with the Discord
domains in their include list, exclude Microsoft's domains, and pass
`--hostlist-auto=/var/lib/zapret2/auto-hosts.txt`, so they also add a host to
that file when connections to it keep failing. `nfqws2 --help` on this host
gives the defaults: 3 failed attempts within 60 s. `quic` only reads the same
file, so a host reaches QUIC treatment only after the `http` or `tls` profile
has learnt it. The zapret2 manual says a profile with an automatic list applies
to every host that has a name, which is why autodetection can add hosts that
break under the TCP MD5 fake; Microsoft's domains are excluded for that reason
(`3372db2`), and another host that breaks the same way needs another exclusion
in `nixosModules/zapret2.nix`. The manual's statement was not tested here.

The list survives rebuilds and reboots. It is `/var/lib/zapret2/auto-hosts.txt`
in the service's state folder (`StateDirectory=zapret2`), and `ExecStartPre`
creates it empty when it is missing. Read it with
`sudo cat /var/lib/zapret2/auto-hosts.txt`; it held 60 hosts on nixos-rog on
2026-11-02. Emptying or deleting the file was not run.

**WARP proxy.** `usque.service` runs `usque socks` on `127.0.0.1:1080`
(`oruc.warpProxy` holds the address). It carries only the traffic of an app that
points at it. `usque` keeps one registered WARP device in
`/var/lib/usque/config.json` (`sudo ls -l /var/lib/usque` lists it, owned by the
`usque` user). `preStart` registers a device when that file is missing or empty. When the
machine is offline at boot, registration fails and the service restarts with a
growing delay (`RestartSec=3`, up to `RestartMaxDelaySec=5min`), so it does not
ask Cloudflare every 3 s. Removing `config.json` therefore makes the next start
register a new device; that step was not run.

`sudo systemctl status nfqws2@default usque` shows whether either service runs,
and both raise the failure popup ([Failure popups](#failure-popups)).

## nixos-desktop case fans

`machines/nixos-desktop/fans.nix` runs `case-fans.service`, a daemon
(`fan-control.py`) that owns channels 1, 3, 5 and 7 of the motherboard's
nct6687 chip: the radiator fans, the rear fan and the two intake chains. Every
2 s it turns the filtered CPU (`k10temp` Tctl) and GPU (`amdgpu` edge)
temperatures into a target RPM per channel, and sets the PWM that holds that
RPM from each channel's tach reading and its measured PWM-to-RPM table. In
normal mode the intake target never drops below 0.85 x the radiator RPM plus
0.30 x the rear RPM, so the case keeps positive pressure; at a filtered Tctl of
85 C or a raw Tctl of 89 C all four channels run at full speed instead. The
curves and pressure weights live in `settings` in `fans.nix`, and the measured
tables in `fan-tables.json`. To measure a channel's table again, stop the
service and run the measurement as a transient unit, so the channel returns to
the BIOS however the run ends:

```sh
sudo systemctl stop case-fans
sudo systemd-run --wait --pipe -p ExecStopPost="$(command -v case-fans-control) --restore N" "$(command -v case-fans-control)" --calibrate N
sudo systemctl start case-fans
```

The measurement aborts when Tctl reaches 70 C, so run it while the machine is
idle. It prints one JSON object with the keys `channel`, `floor_pwm` and
`table`. Replace the object with the same `channel` in `fan-tables.json` (`radiator` is
channel 1, `rear` is 3, and the list `intakes` holds channels 5 and 7) with it. `floor_pwm`
already holds a margin of 6 PWM above the lowest PWM at which the fan turned.
Then commit and deploy, because the service reads the table from the system
that the deploy builds.

When the daemon stops, crashes, misses its 10 s watchdog or cannot read a
sensor, `ExecStopPost` hands the four channels back to the BIOS curves. The
BIOS keeps the pump (channel 2) and the AIO's VRM fan (channel 4). `case-fans
off` stops the daemon until `case-fans on` or the next boot (`on` also clears
the start limit that 3 failures in 10 minutes set), `case-fans status`
prints its state file, and `fan-status` lists every fan.

