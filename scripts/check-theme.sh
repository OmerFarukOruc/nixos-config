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
other of its A and B copies with the scheme's background, that the cursor,
GTK theme and colour preference follow the scheme's dark or light variant, that
the icon theme is the scheme's or stays as picked in System Settings, that the
look keeps its Plasma style, and that the Glass glow has the
scheme's blue. The expected colours come from the scheme's YAML in the pack.
It also checks that an unknown scheme exits 64 and changes nothing, that
`theme --reapply` finishes a switch interrupted after the stored scheme
changed, that it falls back to the record scheme when no scheme is stored,
that neither run changes the running session's KDE colour scheme, and that
the pack is a GC root. It prints a skip line for each scheme whose Plasma
checks cannot run.

For Noctalia, DMS, rofi, vicinae, niri, wlogout, mpv and the Plasma splash it
checks that each file holds the scheme's colour. While Noctalia or DMS runs,
it also checks that the shell shows the custom palette in the scheme's dark or
light mode, and in a niri session that niri's configuration parses and that
niri reports a successful reload after the switch.

For VS Code it checks that settings.json names the scheme's colour theme and
holds its sidebar colour after each switch, and that `theme` leaves a
settings.json that does not parse byte-identical and reports the failed
reload. With --contrast it first checks, for every scheme in the pack, that
each text colour the VS Code theme draws on an accent background reaches
4.5:1 against it, and that its muted text and comments reach 4.5:1 on the
editor and side bar backgrounds.

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

holds_required() {
  [[ -e $pack/$1/$2 ]] || fail "$1: the pack has no $2"
  holds "$@"
}

check_contrast() {
  python3 -I - "$pack" <<'PYTHON'
import re
import sys
from pathlib import Path

pack = Path(sys.argv[1])
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
for line in failures[:20]:
    print(f"check-theme: {line}", file=sys.stderr)
if failures:
    sys.exit(f"check-theme: {len(failures)} VS Code contrast failures")
print(
    f"ok contrast: VS Code text in {checked} schemes;"
    f" {skipped} use their own theme and were skipped"
)
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
  if [[ -n $icons_before && $icons_before != breeze && $icons_before != breeze-dark ]] &&
    ! grep -qxF "$icons_before" "$pack"/*/.oruc/icons; then
    icons=$icons_before
  fi
  cursor=$(<"$pack/$slug/.oruc/cursor")
  gtk=$(<"$pack/$slug/.oruc/gtk")
  [[ $(kdeglobal kdeglobals Icons Theme) == "$icons" ]] || fail "$slug: the icon theme is not $icons"
  [[ $(kdeglobal kcminputrc Mouse cursorTheme) == "$cursor" ]] || fail "$slug: the cursor is not $cursor"
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

check_session() {
  local slug=$1 polarity
  polarity=$(cat "$pack/$slug/.oruc/polarity")
  holds "$slug" .local/share/rofi/themes/custom.rasi "background-color: #$base00;"
  holds "$slug" .local/share/vicinae/themes/oruc-base16.toml "background = \"#$base00\""
  holds "$slug" .local/share/vicinae/themes/oruc-base16.toml "variant = \"$polarity\""
  holds "$slug" .config/wlogout/style.css "border-color: #$base0D;"
  holds "$slug" .config/mpv/script-opts/modernz.conf "seekbarfg_color=#$base0D"
  holds "$slug" .config/mpv/oruc-colors.conf "osd-color=#$base05"
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
  check_contrast || fail "VS Code contrast"
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

previous=$original
for slug in "$@"; do
  plasma_before=
  icons_before=
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
  theme "$slug" >/dev/null || fail "theme $slug exited $?"
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
  check_session "$slug"
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
