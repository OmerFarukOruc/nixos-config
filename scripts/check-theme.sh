#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: scripts/check-theme.sh [--host HOST] [--contrast] SCHEME...

Runs `theme SCHEME` for each SCHEME on this host, or on HOST over SSH, and
checks that theme/current points at the scheme in the theme pack, that every
colour file under $HOME resolves into it, that each file holds the colour of
the slot its app uses, and that a tmux server and two Neovim instances started
before the switch show the new colours. On a host with Plasma whose desktop
session runs, it also checks that the session's KDE colour scheme moved to the
other of its A and B copies with the scheme's background, that the GTK theme
and colour preference follow the scheme's dark or light variant, that the
cursor becomes the scheme's recoloured Bibata within 60 s, with base05 as the
24 px arrow's fill, that the icon theme is the scheme's or stays as picked in
System Settings, that a Papirus-Oruc icon theme links its folders to the
Papirus colour its name gives, that the
look keeps its Plasma style, and that the Glass glow has the
scheme's blue. The expected colours come from the scheme's YAML in the pack.
It also checks that an unknown scheme exits 64 and changes nothing, that
`theme --reapply` finishes a switch interrupted after the stored scheme
changed, that it falls back to the record scheme when no scheme is stored,
that neither run changes the running session's KDE colour scheme, and that
the pack is a GC root. It prints a skip line for each scheme whose Plasma
checks cannot run.

For Noctalia, DMS, rofi, vicinae, niri, wlogout, mpv and the Plasma splash it
checks that each file holds the scheme's colour; for mpv's OSD and subtitle
colours it asks mpv itself to read the file. While Noctalia or DMS runs, it
also checks that the shell shows the custom palette in the scheme's dark or
light mode, and in a niri session that niri's configuration parses and that
niri reports a successful reload after the switch.

It checks that `theme` activates no Home Manager generation, that it stores
the scheme in /var/lib/oruc/theme/scheme, that the console palette holds the
scheme's 16 ANSI colours, that the login theme links to the file
oruc-theme-root writes and that file's text colour is the scheme's base05, or
the record scheme's for a light scheme, and that oruc-theme-root refuses an
unknown scheme with exit 64 and changes neither the stored scheme, the console
nor the login screen. On a Limine host it checks that limine.conf holds the
scheme's base00 as backdrop and term_background, and that every other line
stays as it was. On nixos-rog it checks that the keyboard's Aura light turns
static in the scheme's base09 within 5 s. It checks that oruc-wallpaper-path
prints the scheme's own wallpaper from assets/wallpapers, or a PNG it rendered
once into ~/.cache/oruc/wallpapers, and in a Plasma session that the desktop
shows it. Outside Plasma, on a host with niri, it checks dconf's colour
preference, recoloured cursor and icon theme, and that niri's oruc-cursor.kdl
names that cursor.

For VS Code it checks that settings.json names the scheme's colour theme and
holds its sidebar colour after each switch, and that `theme` leaves a
settings.json that does not parse byte-identical and reports the failed
reload. With --contrast it first checks, for every scheme in the pack, that
each text colour the VS Code theme draws on an accent background reaches
4.5:1 against it, that its muted text and comments reach 4.5:1 on the editor
and side bar backgrounds, that the Claude Code status line's segment colours
are the scheme's and their text reaches 4.5:1 on them, and that OBS's text on
its accent colours, SourceGit's badge and conflict text, the text Vesktop
and Telegram draw on their accent fills, the text on GTK's accent,
destructive, success, warning and error colours, on KDE's selection, on
tmux's current window, on Noctalia's and DMS's accent colours, and on the
login screen's button and highlight reach 4.5:1.

For Codex, opencode, pi, Konsole, Thunderbird, Obsidian, SourceGit, OBS,
Vesktop, Telegram, Spotify and the Cursor editor it checks that their theme
files hold the scheme's base00, that Spotify's colors.css links to the
pointer's spicetify-colors.css fact, that Pywalfox's colors.json lists the scheme's 16 colours in
order, and that the Cursor editor's settings.json selects the Oruc Base16
theme of the scheme's dark or light variant. `oruc-app-settings --check` then
checks that every settings file the switch sets, such as ~/.codex/config.toml,
Brave's Preferences or jadx's gui.json, holds the scheme's values; while an
app that writes its own settings runs, the switch leaves them alone, and the
script prints a skip line for it. A browser waits per profile, so a closed
profile must hold the values while another profile runs.

It switches back to the scheme that was active, and exits 1 at the first
failed check, naming it.
EOF
  exit 64
}

host=
contrast=
while [[ ${1:-} == --* ]]; do
  case $1 in
    --host)
      host=${2:-}
      [[ -n $host ]] || usage
      shift 2
      ;;
    --contrast)
      contrast=--contrast
      shift
      ;;
    *) usage ;;
  esac
done
[[ $# -gt 0 ]] || usage
for slug in "$@"; do
  [[ $slug =~ ^[a-z0-9-]+$ ]] || usage
done

if [[ -n $host ]]; then
  remote=/tmp/check-theme-$$.sh
  scp -q "$0" "$host:$remote"
  exec ssh "$host" "bash $remote $contrast $* </dev/null; rc=\$?; rm -f $remote; exit \$rc"
fi

state=${XDG_STATE_HOME:-$HOME/.local/state}/oruc
pack=$state/theme/pack
scratch=$(mktemp -d)
tmux_socket=oruc-check-theme-$$
nvim_pids=()
vscode_settings=${XDG_CONFIG_HOME:-$HOME/.config}/Code/User/settings.json
vscode_saved=
niri_events=
niri_stream=

fail() {
  echo "check-theme: $*" >&2
  exit 1
}

read -r original record < <(theme | sed -nE 's/^active: ([^ ]+) \(default: ([^)]+)\)$/\1 \2/p') || true
[[ -n ${original:-} && -n ${record:-} ]] || fail "theme printed no active and default scheme"

cleanup() {
  [[ -z $vscode_saved ]] || cp "$vscode_saved" "$vscode_settings"
  tmux -L "$tmux_socket" kill-server 2>/dev/null || true
  kill "${nvim_pids[@]}" 2>/dev/null || true
  [[ -z $niri_stream ]] || kill "$niri_stream" 2>/dev/null || true
  rm -r "${scratch:?}"
  theme "$original" >/dev/null || echo "check-theme: could not switch back to $original" >&2
}
trap cleanup EXIT

color() {
  sed -nE "s/^[[:space:]]+$2:[[:space:]]*\"#([0-9a-fA-F]{6})\".*/\1/p" "$pack/$1/.oruc/source.yaml" |
    tr '[:upper:]' '[:lower:]'
}

holds() {
  local slug=$1 key=$2 text=$3
  [[ -e $pack/$slug/$key ]] || return 0
  grep -qiF -- "$text" "$HOME/$key" || fail "$slug: ~/$key does not hold $text"
}

mpv_reads_colors() {
  local slug=$1 colour=$2 key=.config/mpv/oruc-colors.conf
  [[ -e $pack/$slug/$key ]] || return 0
  local log
  log=$(mpv --no-config --include="$HOME/$key" --msg-level=cplayer=v --idle=no 2>&1) ||
    fail "$slug: mpv exited $? with ~/$key"
  for option in osd-color sub-color; do
    grep -qiF "Setting option '$option' = '#$colour'" <<<"$log" ||
      fail "$slug: mpv does not read $option #$colour from ~/$key"
  done
}

recoloured_cursor() {
  local slug=$1 name
  read -r name _ <"$pack/$slug/.oruc/pointer-cursor"
  for _ in $(seq 120); do
    [[ -e $HOME/.local/share/icons/$name/index.theme ]] && break
    sleep 0.5
  done
  [[ -e $HOME/.local/share/icons/$name/index.theme ]] ||
    fail "$slug: ~/.local/share/icons/$name was not built within 60 s"
  printf '%s\n' "$name"
}

waits_for() {
  local want=$1
  shift
  for _ in $(seq 40); do
    [[ $("$@") == "$want" ]] && return 0
    sleep 0.5
  done
  return 1
}

check_niri_cursor() {
  local slug=$1 cursor=$2
  [[ -e $pack/$slug/.config/niri/oruc-theme.kdl ]] || return 0
  grep -qF "xcursor-theme \"$cursor\"" "$HOME/.config/niri/oruc-cursor.kdl" ||
    fail "$slug: ~/.config/niri/oruc-cursor.kdl does not name $cursor"
}

check_cursor_frame() {
  local slug=$1 name=$2 fill
  fill=$(
    python3 -I - "$HOME/.local/share/icons/$name/cursors/left_ptr" <<'PYTHON'
import collections
import struct
import sys

data = open(sys.argv[1], "rb").read()
count = struct.unpack("<I", data[12:16])[0]
for i in range(count):
    _, size, position = struct.unpack("<III", data[16 + 12 * i : 28 + 12 * i])
    if size == 24:
        width, height = struct.unpack("<II", data[position + 16 : position + 24])
        pixels = struct.unpack(f"<{width * height}I", data[position + 36 : position + 36 + 4 * width * height])
        opaque = collections.Counter(p & 0xFFFFFF for p in pixels if p >> 24 == 0xFF)
        print(f"{opaque.most_common(1)[0][0]:06x}")
        break
PYTHON
  )
  [[ $fill == "$base05" ]] || fail "$slug: the 24 px arrow of $name is filled with $fill, not base05 $base05"
}

check_folder_icons() {
  local slug=$1 icons=$2 colour dir name
  [[ $icons == Papirus-Oruc-* ]] || return 0
  colour=${icons#Papirus-Oruc-}
  colour=${colour%-*}
  for dir in "$HOME/.nix-profile/share/icons" "/etc/profiles/per-user/$USER/share/icons"; do
    [[ -e $dir/$icons/index.theme ]] || continue
    for name in folder inode-directory; do
      [[ $(readlink -f "$dir/$icons/48x48/places/$name.svg") == */folder-"$colour".svg ]] ||
        fail "$slug: $icons/48x48/places/$name.svg does not resolve to folder-$colour.svg"
    done
    return 0
  done
  fail "$slug: the icon theme $icons is not installed"
}

holds_required() {
  [[ -e $pack/$1/$2 ]] || fail "$1: the pack has no $2"
  holds "$@"
}

check_contrast() {
  python3 -I - "$pack" "$system_pack" <<'PYTHON'
import json
import re
import sys
from pathlib import Path

pack = Path(sys.argv[1])
system_pack = Path(sys.argv[2])
color = re.compile(r'^\s*"([^"]+)": "#([0-9a-fA-F]+)"', re.M)


def luminance(hex6):
    def linear(channel):
        v = int(channel, 16) / 255
        return v / 12.92 if v <= 0.03928 else ((v + 0.055) / 1.055) ** 2.4

    r, g, b = (linear(hex6[i : i + 2]) for i in (0, 2, 4))
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def contrast(a, b):
    la, lb = luminance(a), luminance(b)
    return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)


def words(text):
    return set(text.split())


accent = words(
    """activityBarBadge.foreground button.foreground button.secondaryForeground
    debugView.stateLabelForeground extensionBadge.remoteForeground
    extensionButton.prominentForeground inputValidation.errorForeground
    inputValidation.infoForeground inputValidation.warningForeground
    notification.buttonForeground notification.errorForeground
    notification.infoForeground notification.warningForeground
    statusBar.debuggingForeground statusBar.foreground
    statusBar.noFolderForeground statusBarItem.errorForeground
    statusBarItem.prominentForeground statusBarItem.remoteForeground
    statusBarItem.warningForeground"""
)
hovers = {
    "button.hoverBackground": "button.foreground",
    "button.secondaryHoverBackground": "button.secondaryForeground",
    "extensionButton.prominentHoverBackground": "extensionButton.prominentForeground",
    "notification.buttonHoverBackground": "notification.buttonForeground",
    "statusBarItem.hoverBackground": "statusBar.foreground",
    "statusBarItem.prominentHoverBackground": "statusBarItem.prominentForeground",
}
faint = words(
    """descriptionForeground input.placeholderForeground
    activityBar.inactiveForeground tab.inactiveForeground
    tab.unfocusedInactiveForeground editorLineNumber.foreground
    editorCodeLens.foreground peekViewResult.lineForeground
    peekViewTitleDescription.foreground panelTitle.inactiveForeground
    titleBar.inactiveForeground pickerGroup.foreground
    gitDecoration.ignoredResourceForeground
    debugIcon.breakpointUnverifiedForeground"""
)
dim = words(
    """disabledForeground icon.foreground tab.unfocusedActiveForeground
    editorLineNumber.activeForeground debugIcon.breakpointDisabledForeground"""
)
tokens = {
    "Comment": "faint",
    "Markdown - Line Break": "faint",
    "Operator, Misc": "foreground",
    "Markdown - Plain": "foreground",
}
surfaces = ("editor.background", "sideBar.background")


def background(key):
    return re.sub(r"([fF])oreground$", lambda m: "Background" if m[1] == "F" else "background", key)


def token(text, name):
    found = re.search(rf'"name": "{re.escape(name)}",.*?"foreground": "#([0-9a-fA-F]+)"', text, re.S)
    return found[1] if found else ""


failures = []
checked = skipped = 0
for slug in (pack / "slugs").read_text().split():
    facts = pack / slug / ".oruc"
    theme_file = pack / slug / ".config/oruc/vscode-theme.json"
    names = ("vscode-pairs", "vscode-text", "vscode-label")
    if not theme_file.exists() or not all((facts / name).exists() for name in names):
        failures.append(f"{slug}: the pack has no VS Code theme or its facts")
        continue
    if not (facts / "vscode-label").read_text().startswith("Oruc Base16 "):
        skipped += 1
        continue
    checked += 1
    pairs = {tuple(line.split()) for line in (facts / "vscode-pairs").read_text().splitlines()}
    if pairs != {(fg, background(fg)) for fg in accent}:
        failures.append(f"{slug}: the accent pairs differ from the {len(accent)} expected")
    roles = dict(line.split() for line in (facts / "vscode-text").read_text().splitlines())
    if {k for k, r in roles.items() if r == "faint"} != faint or {k for k, r in roles.items() if r == "dim"} != dim:
        failures.append(f"{slug}: the faint or dim keys differ from the expected lists")
    if roles.get("editor.foreground") != "foreground":
        failures.append(f"{slug}: editor.foreground is not lifted as text")
    text = theme_file.read_text()
    values = dict(color.findall(text))
    for name, role in tokens.items():
        values[name] = token(text, name)
        roles[name] = role
    shared = [
        bg
        for bg in surfaces
        if bg == surfaces[0]
        or any(all(contrast(x, values.get(s, x)) >= 4.5 for s in surfaces) for x in ("000000", "ffffff"))
    ]
    checks = sorted(pairs) + [(fg, hover) for hover, fg in hovers.items()]
    checks += [(key, bg) for key in sorted(roles) for bg in shared]
    for fg, bg in checks:
        if len(values.get(fg, "")) != 6 or len(values.get(bg, "")) != 6:
            failures.append(f"{slug}: {fg} or {bg} is not a six-digit colour")
            continue
        ratio = contrast(values[fg], values[bg])
        if ratio < 4.5:
            failures.append(f"{slug}: {fg} #{values[fg]} on {bg} #{values[bg]} is {ratio:.2f}:1")
    editor = values["editor.background"]
    level = {r: [contrast(values[k], editor) for k in roles if roles[k] == r] for r in ("faint", "dim", "foreground")}
    if max(level["faint"]) > min(level["dim"]) + 0.05 or max(level["dim"]) > min(level["foreground"]) + 0.05:
        failures.append(f"{slug}: faint, dim and normal text are out of order on the editor")
    inactive, active = values["editorLineNumber.foreground"], values["editorLineNumber.activeForeground"]
    if active == inactive and inactive != values["editor.foreground"]:
        failures.append(f"{slug}: the active line number looks like the others")
text_segments = {
    "dir": "base02", "git": "base09", "model": "base0D", "account": "base0C", "clock": "base0E", "cost": "base0F",
}
bar_segments = {"ctx": "base01", "five_hour": "base02", "seven_day": "base01"}
levels = ("low", "mid", "high")


def hex_of(rgb):
    return "".join(f"{int(part):02x}" for part in rgb.split(";"))


def statusline_failures(slug):
    fact = pack / slug / ".oruc/statusline"
    if not fact.exists():
        return [f"{slug}: the pack has no status line fact"]
    data = json.loads(fact.read_text())
    yaml = (pack / slug / ".oruc/source.yaml").read_text()
    found = []
    for name, slot in {**text_segments, **bar_segments}.items():
        segment = data.get("segments", {}).get(name, {})
        scheme = re.search(rf'^\s+{slot}:\s*"#([0-9a-fA-F]{{6}})"', yaml, re.M)
        if "bg" not in segment:
            found.append(f"{slug}: the {name} segment has no bg")
            continue
        bg = hex_of(segment["bg"])
        if not scheme or bg != scheme[1].lower():
            found.append(f"{slug}: the {name} segment is not the scheme's {slot}")
        if name in text_segments:
            drawn = {"fg": segment.get("fg")}
        else:
            used = data.get("used", {}).get(name, {})
            drawn = {f"used {level}": used.get(level) for level in levels}
        for label, value in drawn.items():
            if value is None:
                found.append(f"{slug}: the {name} segment has no {label}")
                continue
            ratio = contrast(hex_of(value), bg)
            if ratio < 4.5:
                found.append(f"{slug}: the {name} segment's {label} {value} is {ratio:.2f}:1")
    return found


obs_var = re.compile(r"^\s*--([a-z_0-9]+): #([0-9a-fA-F]{6});", re.M)
telegram_var = re.compile(r"^([A-Za-z0-9_]+): #([0-9a-f]{6});", re.M)


def telegram_pairs(colors):
    pairs = [
        ("windowFgActive", "windowBgActive"),
        ("sideBarBadgeFg", "sideBarBadgeBg"),
        ("sideBarBadgeFg", "sideBarBadgeBgMuted"),
        ("searchedTextCurrentMatchFg", "searchedTextCurrentMatchBg"),
    ]
    for key in colors:
        if re.fullmatch(r"historyPeer\dUserpicBg2?", key):
            pairs.append(("windowFgActive", key))
        elif key.startswith("settingsIconBg"):
            pairs.append(("settingsIconFg", key))
        elif re.fullmatch(r"premiumButtonBg\d", key):
            pairs.append(("premiumButtonFg", key))
    return pairs


vesktop_var = re.compile(r"^\s*--([a-z0-9-]+): #([0-9a-f]{6}) !important;", re.M)
vesktop_pairs = [
    ("control-primary-text-default", "control-primary-background-default"),
    ("control-primary-text-hover", "control-primary-background-hover"),
    ("control-primary-text-active", "control-primary-background-active"),
    ("badge-primary-text", "badge-primary-background"),
    ("button-filled-brand-text", "button-filled-brand-background"),
    ("button-filled-brand-text-hover", "button-filled-brand-background-hover"),
    ("white", "brand-260"),
    ("white", "brand-500"),
    ("mention-foreground", "mention-background"),
    ("white", "green-360"),
    ("white", "status-positive"),
    ("status-positive-text", "status-positive-background"),
    ("white", "button-danger-background"),
    ("white", "menu-item-danger-hover-bg"),
    ("white", "menu-item-danger-active-bg"),
]


def app_failures(slug):
    found = []
    polarity = (pack / slug / ".oruc/polarity").read_text().strip()
    obs = pack / slug / f".config/obs-studio/themes/Oruc{polarity.title()}.ovt"
    if obs.exists():
        colors = dict(obs_var.findall(obs.read_text()))
        for name in ("primary", "primary_light", "primary_dark"):
            ratio = contrast(colors["text"], colors[name])
            if ratio < 4.5:
                found.append(f"{slug}: OBS text on {name} is {ratio:.2f}:1")
    sourcegit = pack / slug / ".config/oruc/sourcegit-theme.json"
    if sourcegit.exists():
        basic = json.loads(sourcegit.read_text())["BasicColors"]
        for text, background in (("BadgeFG", "Badge"), ("Conflict.Foreground", "Conflict")):
            ratio = contrast(basic[text][-6:], basic[background][-6:])
            if ratio < 4.5:
                found.append(f"{slug}: SourceGit {text} on {background} is {ratio:.2f}:1")
    telegram = pack / slug / ".config/oruc/oruc.tdesktop-palette"
    if telegram.exists():
        colors = dict(telegram_var.findall(telegram.read_text()))
        for text, background in telegram_pairs(colors):
            ratio = contrast(colors[text], colors[background])
            if ratio < 4.5:
                found.append(f"{slug}: Telegram {text} on {background} is {ratio:.2f}:1")
    vesktop = pack / slug / ".config/vesktop/themes/oruc.css"
    if vesktop.exists():
        block = vesktop.read_text().rsplit(".visual-refresh {", 1)[1]
        colors = dict(vesktop_var.findall(block))
        for text, background in vesktop_pairs:
            if text not in colors or background not in colors:
                found.append(f"{slug}: Vesktop sets no {text} or {background}")
                continue
            ratio = contrast(colors[text], colors[background])
            if ratio < 4.5:
                found.append(f"{slug}: Vesktop {text} on {background} is {ratio:.2f}:1")
    return found


gtk_var = re.compile(r"^@define-color ([a-z_]+_color) #([0-9a-fA-F]{6});", re.M)
gtk_fills = ("accent", "destructive", "success", "warning", "error")
kde_selection = re.compile(r"^\[Colors:Selection\]\n(.*?)(?=^\[)", re.M | re.S)
kde_key = re.compile(r"^(ForegroundNormal|BackgroundNormal)=(\d+),(\d+),(\d+)$", re.M)
tmux_style = re.compile(r'^set -g ([a-z-]+) "fg=#([0-9a-fA-F]{6}),bg=#([0-9a-fA-F]{6})', re.M)
noctalia_fills = ("Primary", "Secondary", "Tertiary", "Error")
sddm_pairs = (("LoginButtonTextColor", "LoginButtonBackgroundColor"), ("HighlightTextColor", "HighlightBackgroundColor"))


def desktop_failures(slug):
    found = []

    def check(app, text, background, fg, bg):
        ratio = contrast(fg, bg)
        if ratio < 4.5:
            found.append(f"{slug}: {app} {text} #{fg} on {background} #{bg} is {ratio:.2f}:1")

    gtk = dict(gtk_var.findall((pack / slug / ".config/gtk-4.0/oruc-colors.css").read_text()))
    for fill in gtk_fills:
        text, background = f"{fill}_fg_color", f"{fill}_bg_color"
        check("GTK", text, background, gtk[text], gtk[background])
    kde = kde_selection.search((pack / slug / ".local/share/oruc/kde/OrucBase16.colors").read_text())
    keys = {key: "".join(f"{int(c):02x}" for c in rgb) for key, *rgb in kde_key.findall(kde[1])}
    check("KDE", "Selection ForegroundNormal", "BackgroundNormal", keys["ForegroundNormal"], keys["BackgroundNormal"])
    styles = {style: (fg, bg) for style, fg, bg in tmux_style.findall((pack / slug / ".config/tmux/oruc-theme.conf").read_text())}
    check("tmux", "window-status-current-style fg", "bg", *styles["window-status-current-style"])
    noctalia = json.loads((pack / slug / ".config/noctalia/palettes/oruc-base16.json").read_text())["dark"]
    for fill in noctalia_fills:
        check("Noctalia", f"mOn{fill}", f"m{fill}", noctalia[f"mOn{fill}"][1:], noctalia[f"m{fill}"][1:])
    dms = json.loads((pack / slug / ".config/dms/oruc-theme.json").read_text())["dark"]
    check("DMS", "primaryText", "primary", dms["primaryText"][1:], dms["primary"][1:])
    sddm = dict(re.findall(r'^([A-Za-z]+)="#([0-9a-fA-F]{6})"$', (system_pack / slug / "sddm.conf.user").read_text(), re.M))
    for text, background in sddm_pairs:
        check("SDDM", text, background, sddm[text], sddm[background])
    return found


statusline = []
apps = []
desktop = []
slugs = (pack / "slugs").read_text().split()
for slug in slugs:
    statusline += statusline_failures(slug)
    apps += app_failures(slug)
    desktop += desktop_failures(slug)
for line in (failures + statusline + apps + desktop)[:20]:
    print(f"check-theme: {line}", file=sys.stderr)
if failures or statusline or apps or desktop:
    sys.exit(
        f"check-theme: {len(failures)} VS Code, {len(statusline)} status line,"
        f" {len(apps)} OBS, SourceGit, Vesktop or Telegram"
        f" and {len(desktop)} GTK, KDE, tmux, Noctalia, DMS or SDDM contrast failures"
    )
print(
    f"ok contrast: VS Code text in {checked} schemes;"
    f" {skipped} use their own theme and were skipped"
)
print(f"ok contrast: the Claude Code status line in {len(slugs)} schemes")
print(f"ok contrast: OBS, SourceGit, Vesktop and Telegram accent text in {len(slugs)} schemes")
print(f"ok contrast: GTK, KDE, tmux, Noctalia, DMS and login screen accent text in {len(slugs)} schemes")
PYTHON
}

check_vscode() {
  local slug=$1 label polarity sidebar
  holds_required "$slug" .config/oruc/vscode-theme.json "\"editor.background\": \"#$base00\""
  holds_required "$slug" .config/oruc/vscode-colors.json "\"#$base01"
  label=$(<"$pack/$slug/.oruc/vscode-label")
  polarity=$(<"$pack/$slug/.oruc/polarity")
  [[ $label == "Oruc Base16 ${polarity^}" || $label == "Warm Burnout ${polarity^}" ]] ||
    fail "$slug: the VS Code colour theme $label does not match the scheme's polarity"
  [[ $(jq -r '."workbench.colorTheme"' "$vscode_settings") == "$label" ]] ||
    fail "$slug: VS Code settings.json does not name the colour theme $label"
  sidebar=$(jq -r '."workbench.colorCustomizations"."sideBar.background"' "$vscode_settings")
  [[ ${sidebar,,} == "#$base01"* ]] || fail "$slug: VS Code's sidebar colour is $sidebar, not #$base01"
}

decimal() {
  printf '%d,%d,%d' "0x${1:0:2}" "0x${1:2:2}" "0x${1:4:2}"
}

kdeglobal() {
  kreadconfig6 --file "$1" --group "$2" --key "$3"
}

plasma_session() {
  if [[ ! -e $pack/$1/.local/share/oruc/kde/OrucBase16Glass.colors ]]; then
    echo "skip Plasma checks for $1: this host has no Plasma"
  elif ! systemctl --user show-environment | grep '^WAYLAND_DISPLAY=' >/dev/null; then
    echo "skip Plasma checks for $1: no desktop session runs"
  elif [[ $(kdeglobal kdeglobals General ColorScheme) != OrucBase16* ]]; then
    echo "skip Plasma checks for $1: the session runs the colour scheme $(kdeglobal kdeglobals General ColorScheme)"
  else
    return 0
  fi
  return 1
}

check_app_settings() {
  local slug=$1 polarity side line
  polarity=$(<"$pack/$slug/.oruc/polarity")
  side=${polarity^}
  holds_required "$slug" .codex/themes/oruc.tmTheme "<string>#$base00</string>"
  holds_required "$slug" .config/opencode/themes/oruc.json "\"background\":\"#$base00\""
  holds "$slug" .pi/agent/themes/oruc.json "\"pageBg\":\"#$base00\""
  holds "$slug" .local/share/konsole/OrucBase16.colorscheme "Color=$(decimal "$base00")"
  holds "$slug" .config/oruc/thunderbird.css "--layout-background-0: #$base00"
  holds "$slug" .config/oruc/obsidian.css "--background-primary: #$base00"
  holds "$slug" .config/oruc/sourcegit-theme.json "\"Window\":\"#FF${base00^^}\""
  holds "$slug" ".config/obs-studio/themes/Oruc$side.ovt" "--grey7: #$base00"
  holds "$slug" .config/oruc/cursor-colors.json "\"Oruc Base16 $side\""
  holds "$slug" .config/vesktop/themes/oruc.css "--base00: #$base00;"
  holds "$slug" .config/oruc/oruc.tdesktop-palette "windowBg: #$base00;"
  if command -v spotify >/dev/null && [[ -e $pack/$slug/.oruc/spicetify-colors.css ]]; then
    line=$(readlink "$(dirname "$(readlink -f "$(command -v spotify)")")/Apps/xpui/colors.css")
    [[ $line == "$state/theme/current/.oruc/spicetify-colors.css" ]] ||
      fail "$slug: Spotify's colors.css links to $line"
    grep -qiF -- "--spice-main: #$base00;" "$line" ||
      fail "$slug: Spotify's colors.css does not hold base00"
  fi
  if [[ -e $pack/$slug/.oruc/pywal-colors ]]; then
    [[ $(jq -r '.colors | keys_unsorted | join(" ")' "${XDG_CACHE_HOME:-$HOME/.cache}/wal/colors.json") == "$(printf 'color%d ' $(seq 0 15) | sed 's/ $//')" ]] ||
      fail "$slug: ~/.cache/wal/colors.json does not list color0 to color15 in order"
    [[ $(jq -r .colors.color0 "${XDG_CACHE_HOME:-$HOME/.cache}/wal/colors.json") == "#$base00" ]] ||
      fail "$slug: Pywalfox's color0 is not the scheme's base00"
  fi
  [[ ! -e $pack/$slug/.config/oruc/cursor-colors.json ]] ||
    [[ $(jq -r '.["workbench.colorTheme"]' "${XDG_CONFIG_HOME:-$HOME/.config}/Cursor/User/settings.json") == "Oruc Base16 $side" ]] ||
    fail "$slug: the Cursor editor's settings.json does not select Oruc Base16 $side"
  oruc-app-settings --check >"$scratch/apps-$slug" || fail "$slug: oruc-app-settings --check found a file the switch left unset"
  while IFS= read -r line; do
    [[ $line != skip* ]] || echo "skip $slug: ${line#skip }"
  done <"$scratch/apps-$slug"
}

check_plasma() {
  local slug=$1 before=$2 previous=$3 icons_before=$4 now base variant bg icons cursor gtk style preference glow
  now=$(kdeglobal kdeglobals General ColorScheme)
  base=${before%[AB]}
  if [[ $slug == "$previous" && $before == "${base}"[AB] ]]; then
    [[ $now == "$before" ]] || fail "$slug: theme applied the KDE colours of the scheme that ran again, as $now"
  else
    [[ $now != "$before" && ($now == "${base}A" || $now == "${base}B") ]] ||
      fail "$slug: the KDE colour scheme is $now after $before"
  fi
  bg=$(kdeglobal kdeglobals Colors:Window BackgroundNormal)
  [[ $bg == "$(decimal "$base00")"* ]] || fail "$slug: the KDE window background is $bg, not $(decimal "$base00")"
  variant=$(sed -nE 's/^variant:[[:space:]]*"?([a-z]+)"?.*/\1/p' "$pack/$slug/.oruc/source.yaml")
  icons=$(<"$pack/$slug/.oruc/icons")
  if [[ -n $icons_before ]] && ! grep -qxF -- "$icons_before" "$pack/$slug/.oruc/replaceable-icons"; then
    icons=$icons_before
  fi
  cursor=$(recoloured_cursor "$slug")
  gtk=$(<"$pack/$slug/.oruc/gtk")
  [[ $(kdeglobal kdeglobals Icons Theme) == "$icons" ]] || fail "$slug: the icon theme is not $icons"
  check_folder_icons "$slug" "$icons"
  waits_for "$cursor" kdeglobal kcminputrc Mouse cursorTheme ||
    fail "$slug: the cursor is $(kdeglobal kcminputrc Mouse cursorTheme), not $cursor"
  check_cursor_frame "$slug" "$cursor"
  check_niri_cursor "$slug" "$cursor"
  [[ $(dconf read /org/gnome/desktop/interface/gtk-theme) == "'$gtk'" ]] || fail "$slug: the GTK theme is not $gtk"
  case $base in
    OrucBase16Glass) style=oruc-glass ;;
    *) style=klassy-$variant ;;
  esac
  [[ $(kdeglobal plasmarc Theme name) == "$style" ]] || fail "$slug: the Plasma style is not $style"
  preference=$(dconf read /org/gnome/desktop/interface/color-scheme)
  [[ $preference == "'prefer-$variant'" ]] || fail "$slug: the colour preference is $preference"
  if [[ $base == OrucBase16Glass ]]; then
    glow=$(kdeglobal kwinrc Effect-blurplus GlowColor)
    [[ ${glow,,} == "#10$base0D" ]] || fail "$slug: the Glass glow is $glow, not #10$base0D"
  fi
}

system_scheme=/var/lib/oruc/theme/scheme
login_colors=/var/lib/oruc/theme/sddm/jake_the_dog.conf.user
theme_root=/run/current-system/sw/bin/oruc-theme-root
sddm_link=/run/current-system/sw/share/sddm/themes/sddm-astronaut-theme/Themes/jake_the_dog.conf.user
console_slots=(base00 base08 base0B base0A base0D base0E base0C base05 base03 base08 base0B base0A base0D base0E base0C base07)

console_palette() {
  local slug=$1 slot red green blue reds=() greens=() blues=()
  for slot in "${console_slots[@]}"; do
    IFS=, read -r red green blue <<<"$(decimal "$(color "$slug" "$slot")")"
    reds+=("$red")
    greens+=("$green")
    blues+=("$blue")
  done
  local IFS=,
  printf '%s\n' "${reds[*]}" "${greens[*]}" "${blues[*]}"
}

live_console() {
  cat /sys/module/vt/parameters/default_{red,grn,blu}
}

limine_conf=/boot/limine/limine.conf
limine_keys='^(backdrop|interface_branding_colour|interface_help_colour|interface_help_colour_bright|term_palette|term_palette_bright|term_foreground|term_background|term_foreground_bright|term_background_bright):'

boot_menu_rest() {
  /run/wrappers/bin/sudo -n grep -vE "$limine_keys" "$limine_conf" || true
}

check_boot_menu() {
  local slug=$1 base00
  [[ -n $boot_menu_before ]] || return 0
  base00=$(color "$slug" base00)
  [[ $(/run/wrappers/bin/sudo -n grep -ciE "^(backdrop|term_background): $base00\$" "$limine_conf") == 2 ]] ||
    fail "$slug: $limine_conf does not hold the scheme's base00 as backdrop and term_background"
  [[ $(boot_menu_rest) == "$boot_menu_before" ]] ||
    fail "$slug: theme changed a line of $limine_conf outside the colour keys"
}

check_system() {
  local slug=$1 login_text
  [[ -x $theme_root ]] || fail "$slug: this system has no oruc-theme-root"
  [[ $(readlink "$sddm_link") == "$login_colors" ]] ||
    fail "$slug: the login theme's $sddm_link does not point at $login_colors"
  [[ $(cat "$system_scheme") == "$slug" ]] || fail "$slug: $system_scheme holds $(cat "$system_scheme")"
  [[ $(live_console) == "$(console_palette "$slug")" ]] ||
    fail "$slug: the console palette is not the scheme's 16 ANSI colours"
  if [[ $(cat "$pack/$slug/.oruc/polarity") == light ]]; then
    login_text=$(color "$record" base05)
  else
    login_text=$(color "$slug" base05)
  fi
  grep -qixF "HeaderTextColor=\"#$login_text\"" "$login_colors" ||
    fail "$slug: $login_colors does not hold HeaderTextColor #$login_text"
}

aura_led() {
  busctl --system get-property xyz.ljones.Asusd /xyz/ljones/aura/19b6_3_4 xyz.ljones.Aura LedModeData
}

check_keyboard_light() {
  local slug=$1 red green blue want
  aura_led >/dev/null 2>&1 || return 0
  IFS=, read -r red green blue <<<"$(decimal "$(color "$slug" base09)")"
  want="(uu(yyy)(yyy)ss) 0 0 $red $green $blue "
  for _ in $(seq 25); do
    [[ $(aura_led) == "$want"* ]] && return 0
    sleep 0.2
  done
  fail "$slug: the keyboard's Aura mode is $(aura_led), not static $red $green $blue"
}

check_wallpaper() {
  local slug=$1 path inode extension own=
  command -v oruc-wallpaper-path >/dev/null || return 0
  path=$(oruc-wallpaper-path) || fail "$slug: oruc-wallpaper-path exited $?"
  for extension in png jpg jpeg webp; do
    [[ $path == /nix/store/*/"$slug.$extension" ]] && own=1
  done
  if [[ -z $own ]]; then
    [[ $path == "${XDG_CACHE_HOME:-$HOME/.cache}/oruc/wallpapers/$slug-"*.png ]] ||
      fail "$slug: oruc-wallpaper-path printed $path"
    file -b "$path" | grep -q '^PNG image data' || fail "$slug: $path is not a PNG"
    inode=$(stat -c %i "$path")
    [[ $(oruc-wallpaper-path) == "$path" && $(stat -c %i "$path") == "$inode" ]] ||
      fail "$slug: a second oruc-wallpaper-path rendered $path again"
  fi
  if systemctl --user is-active -q plasma-plasmashell.service; then
    for _ in $(seq 25); do
      grep -qxF "Image=file://$path" "$HOME/.config/plasma-org.kde.plasma.desktop-appletsrc" && return 0
      sleep 0.2
    done
    fail "$slug: Plasma's wallpaper is not $path"
  fi
}

gtk_polarity_applies() {
  [[ -e $pack/$1/.config/niri/oruc-theme.kdl && -e $pack/$1/.oruc/cursor ]] &&
    ! systemctl --user is-active -q plasma-plasmashell.service
}

check_gtk_polarity() {
  local slug=$1 gtk_before=$2 icons_before=$3 polarity cursor icons gtk expected replaceable
  gtk_polarity_applies "$slug" || return 0
  polarity=$(cat "$pack/$slug/.oruc/polarity")
  cursor=$(recoloured_cursor "$slug")
  icons=$(cat "$pack/$slug/.oruc/icons")
  gtk=$(cat "$pack/$slug/.oruc/gtk")
  [[ $(dconf read /org/gnome/desktop/interface/color-scheme) == "'prefer-$polarity'" ]] ||
    fail "$slug: dconf color-scheme is not prefer-$polarity"
  waits_for "'$cursor'" dconf read /org/gnome/desktop/interface/cursor-theme ||
    fail "$slug: dconf cursor-theme is not $cursor"
  check_cursor_frame "$slug" "$cursor"
  check_niri_cursor "$slug" "$cursor"
  check_folder_icons "$slug" "$icons"
  case $gtk_before in
    "" | "'adw-gtk3'" | "'adw-gtk3-dark'") expected="'$gtk'" ;;
    *) expected=$gtk_before ;;
  esac
  [[ $(dconf read /org/gnome/desktop/interface/gtk-theme) == "$expected" ]] ||
    fail "$slug: dconf gtk-theme is not $expected"
  expected=$icons_before
  replaceable=$(sed "s/.*/'&'/" "$pack/$slug/.oruc/replaceable-icons")
  if [[ -z $icons_before ]] || grep -qxF -- "$icons_before" <<<"$replaceable"; then
    expected="'$icons'"
  fi
  [[ $(dconf read /org/gnome/desktop/interface/icon-theme) == "$expected" ]] ||
    fail "$slug: dconf icon-theme is not $expected"
}

check_session() {
  local slug=$1 polarity
  polarity=$(cat "$pack/$slug/.oruc/polarity")
  holds "$slug" .local/share/rofi/themes/custom.rasi "background-color: #$base00;"
  holds "$slug" .local/share/vicinae/themes/oruc-base16.toml "background = \"#$base00\""
  holds "$slug" .local/share/vicinae/themes/oruc-base16.toml "variant = \"$polarity\""
  holds "$slug" .config/wlogout/style.css "border-color: #$base0D;"
  holds "$slug" .config/mpv/script-opts/modernz.conf "seekbarfg_color=#$base0D"
  mpv_reads_colors "$slug" "$base05"
  holds "$slug" .local/share/plasma/look-and-feel/oruc.splash/contents/splash/Splash.qml "color: \"#$base00\""
  if systemctl --user is-active -q noctalia.service; then
    holds_required "$slug" .config/noctalia/palettes/oruc-base16.json "\"#$base00\""
    [[ $(noctalia msg color-scheme-get) == "custom oruc-base16" ]] ||
      fail "$slug: Noctalia shows $(noctalia msg color-scheme-get), not custom oruc-base16"
    [[ $(noctalia msg theme-mode-get) == "$polarity" ]] ||
      fail "$slug: Noctalia's mode is $(noctalia msg theme-mode-get), not $polarity"
  else
    holds "$slug" .config/noctalia/palettes/oruc-base16.json "\"#$base00\""
  fi
  if systemctl --user is-active -q dms.service; then
    holds_required "$slug" .config/dms/oruc-theme.json "\"#$base00\""
    [[ -f $HOME/.config/dms/oruc-theme.json && ! -L $HOME/.config/dms/oruc-theme.json ]] ||
      fail "$slug: ~/.config/dms/oruc-theme.json is not a regular file"
    [[ $(dms ipc call theme getMode) == "$polarity" ]] || fail "$slug: DMS's mode is not $polarity"
  else
    holds "$slug" .config/dms/oruc-theme.json "\"#$base00\""
  fi
  if [[ -n $niri_events ]]; then
    holds_required "$slug" .config/niri/oruc-theme.kdl "active-color \"#$base0D\""
    niri validate -c /etc/niri/config.kdl >/dev/null 2>&1 || fail "$slug: niri validate rejects /etc/niri/config.kdl"
    for _ in $(seq 50); do
      [[ $(grep -c '"ConfigLoaded"' "$niri_events") -ge 2 ]] && break
      sleep 0.2
    done
    tail -n 1 < <(grep '"ConfigLoaded"' "$niri_events") | grep -qF '"failed":false' ||
      fail "$slug: niri did not load the new colours"
    kill "$niri_stream"
    niri_stream=
    niri_events=
  else
    holds "$slug" .config/niri/oruc-theme.kdl "active-color \"#$base0D\""
  fi
}

points_at() {
  [[ $(readlink "$state/theme/current") == "pack/$1" ]] ||
    fail "$2: theme/current is $(readlink "$state/theme/current"), not pack/$1"
}

if [[ -n $contrast ]]; then
  system_pack=$(sed -n 's/^pack=//p' "$theme_root")
  [[ -d $system_pack ]] || fail "$theme_root names no system theme pack"
  check_contrast || fail "contrast"
fi

tmux -L "$tmux_socket" new-session -d -s check
for i in 1 2; do
  nvim --headless -c "call writefile([v:servername], '$scratch/nvim$i')" </dev/null >/dev/null 2>&1 &
  nvim_pids+=("$!")
done
for i in 1 2; do
  for _ in $(seq 50); do
    [[ -s $scratch/nvim$i ]] && break
    sleep 0.2
  done
  [[ -s $scratch/nvim$i ]] || fail "Neovim $i did not start a server"
done

boot_menu_before=
if ! /run/wrappers/bin/sudo -n true 2>/dev/null; then
  echo "skip boot menu checks: sudo -n asks for a password"
elif /run/wrappers/bin/sudo -n test -e "$limine_conf"; then
  boot_menu_before=$(boot_menu_rest)
fi

previous=$original
for slug in "$@"; do
  plasma_before=
  icons_before=
  gtk_before=
  dconf_icons_before=
  if gtk_polarity_applies "$slug"; then
    gtk_before=$(dconf read /org/gnome/desktop/interface/gtk-theme)
    dconf_icons_before=$(dconf read /org/gnome/desktop/interface/icon-theme)
  fi
  if plasma_session "$slug"; then
    plasma_before=$(kdeglobal kdeglobals General ColorScheme)
    icons_before=$(kdeglobal kdeglobals Icons Theme)
  fi
  if niri msg version >/dev/null 2>&1; then
    niri_events=$scratch/niri-events-$slug
    niri msg --json event-stream >"$niri_events" &
    niri_stream=$!
    for _ in $(seq 25); do
      grep -q '"ConfigLoaded"' "$niri_events" && break
      sleep 0.2
    done
  fi
  theme_err=$scratch/theme-$slug.err
  rc=0
  output=$(theme "$slug" 2>"$theme_err") || rc=$?
  cat "$theme_err" >&2
  ((rc == 0)) || fail "theme $slug exited $rc"
  ! grep -qE '^(Activating|Starting Home Manager activation)' <<<"$output" || fail "theme $slug activated a Home Manager generation"
  points_at "$slug" "theme $slug"
  [[ $(cat "$state/scheme") == "$slug" ]] || fail "theme $slug stored $(cat "$state/scheme")"

  while IFS= read -r key; do
    if [[ -L $HOME/$key ]]; then
      [[ $(readlink -f "$HOME/$key") == "$(readlink -f "$pack/$slug/$key")" ]] ||
        fail "$slug: ~/$key does not resolve into pack/$slug"
    else
      cmp -s "$HOME/$key" "$pack/$slug/$key" || fail "$slug: ~/$key differs from pack/$slug/$key"
    fi
  done < <(cd "$pack/$slug" && find -L . -type f ! -path './.oruc/*' | sed 's|^\./||')

  base00=$(color "$slug" base00)
  base01=$(color "$slug" base01)
  base05=$(color "$slug" base05)
  base0D=$(color "$slug" base0D)
  [[ -n $base00 && -n $base01 && -n $base05 && -n $base0D ]] || fail "$slug: source.yaml lacks a slot"
  holds "$slug" .config/ghostty/oruc-colors "$base00"
  holds "$slug" .config/tmux/oruc-theme.conf "#$base01"
  holds "$slug" .config/fzf/fzfrc "#$base0D"
  holds "$slug" .config/starship.toml "#$base0D"
  holds "$slug" .config/atuin/themes/oruc-base16.toml "#$base05"
  holds "$slug" .config/oruc/pandoc-md-theme.css "#$base00"
  holds "$slug" .config/gtk-3.0/oruc-colors.css "#$base00"
  holds "$slug" .config/gtk-4.0/oruc-colors.css "#$base00"
  holds "$slug" ".local/share/org.kde.syntax-highlighting/themes/Oruc Base16.theme" "#$base00"
  holds "$slug" .local/share/oruc/kde/OrucBase16.colors "$(decimal "$base00")"
  holds "$slug" .config/kdeglobals "$(decimal "$base00")"
  if [[ -e $pack/$slug/.config/kdeglobals ]]; then
    for gtkDir in gtk-3.0 gtk-4.0; do
      grep -qF oruc-colors.css "$HOME/.config/$gtkDir/gtk.css" || fail "$slug: ~/.config/$gtkDir/gtk.css does not import oruc-colors.css"
    done
  fi
  [[ -z $plasma_before ]] || check_plasma "$slug" "$plasma_before" "$previous" "$icons_before"
  holds "$slug" .claude/themes/scheme.json "rgb($(decimal "$base00"))"
  check_vscode "$slug"
  check_app_settings "$slug"
  check_session "$slug"
  check_system "$slug"
  check_boot_menu "$slug"
  check_keyboard_light "$slug"
  check_wallpaper "$slug"
  check_gtk_polarity "$slug" "$gtk_before" "$dconf_icons_before"
  if [[ $slug == warm-burnout-* ]]; then
    holds "$slug" .config/oruc/nvim-theme.lua "colorscheme('$slug')"
  else
    holds "$slug" .config/oruc/nvim-theme.lua "#$base00"
  fi

  status=$(tmux -L "$tmux_socket" show -gv status-style)
  [[ ${status,,} == *"bg=#$base01"* ]] || fail "$slug: the running tmux status-style is $status"
  for i in 1 2; do
    bg=$(nvim --server "$(cat "$scratch/nvim$i")" --remote-expr "synIDattr(hlID('Normal'),'bg#')")
    [[ ${bg,,} == "#$base00" ]] || fail "$slug: running Neovim $i has Normal background $bg, not #$base00"
  done
  echo "ok $slug"
  previous=$slug
done

last=${*: -1}
before=$(readlink "$state/theme/current")
if theme not-a-scheme >/dev/null 2>&1; then
  fail "theme not-a-scheme exited 0"
else
  [[ $? == 64 ]] || fail "theme not-a-scheme did not exit 64"
fi
[[ $(cat "$state/scheme") == "$last" && $(readlink "$state/theme/current") == "$before" ]] ||
  fail "theme not-a-scheme changed the stored scheme or theme/current"
echo "ok unknown scheme"

system_mtime=$(stat -c %Y "$system_scheme")
login_before=$(cat "$login_colors")
console_before=$(live_console)
if /run/wrappers/bin/sudo -n "$theme_root" <<<not-a-scheme >/dev/null 2>&1; then
  fail "oruc-theme-root not-a-scheme exited 0"
else
  [[ $? == 64 ]] || fail "oruc-theme-root not-a-scheme did not exit 64"
fi
[[ $(stat -c %Y "$system_scheme") == "$system_mtime" && $(cat "$system_scheme") == "$last" ]] ||
  fail "oruc-theme-root not-a-scheme changed $system_scheme"
[[ $(cat "$login_colors") == "$login_before" && $(live_console) == "$console_before" ]] ||
  fail "oruc-theme-root not-a-scheme changed the login screen or the console"
echo "ok unknown system scheme"

kde_before=$(kdeglobal kdeglobals General ColorScheme 2>/dev/null || true)
kde_unchanged() {
  [[ $(kdeglobal kdeglobals General ColorScheme 2>/dev/null || true) == "$kde_before" ]] ||
    fail "$1 changed the KDE colour scheme of the running session"
}

interrupted=$1
[[ $interrupted != "$last" ]] || interrupted=$record
[[ $interrupted != "$last" ]] || fail "give a second scheme, because $last is the record scheme"
printf '%s\n' "$interrupted" >"$state/scheme"
theme --reapply >/dev/null || fail "theme --reapply exited $?"
points_at "$interrupted" "theme --reapply after an interrupted switch"
kde_unchanged "theme --reapply after an interrupted switch"
echo "ok interrupted switch"

rm "$state/scheme"
theme --reapply >/dev/null || fail "theme --reapply exited $?"
points_at "$record" "theme --reapply without a stored scheme"
kde_unchanged "theme --reapply without a stored scheme"
echo "ok record fallback"

if [[ -e $vscode_settings ]]; then
  vscode_saved=$scratch/vscode-settings.json
  cp "$vscode_settings" "$vscode_saved"
  printf '{ "broken": \n' >"$vscode_settings"
  cp "$vscode_settings" "$scratch/vscode-broken.json"
  output=$(theme "$1" 2>&1) || fail "theme $1 exited $? with a settings.json that does not parse"
  cmp -s "$vscode_settings" "$scratch/vscode-broken.json" || fail "theme changed a settings.json that does not parse"
  grep -qF 'theme: vscode reload failed' <<<"$output" || fail "theme did not report the failed VS Code reload"
  cp "$vscode_saved" "$vscode_settings"
  vscode_saved=
  echo "ok VS Code settings.json that does not parse"
fi

nix-store --gc --print-roots | grep -xF "\"$pack\" -> $(readlink "$pack")" >/dev/null || fail "$pack is not a GC root of the pack it links to"
echo "ok GC root"
