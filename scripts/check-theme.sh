#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: scripts/check-theme.sh [--host HOST] SCHEME...

Runs `theme SCHEME` for each SCHEME on this host, or on HOST over SSH, and
checks that theme/current points at the scheme in the theme pack, that every
colour file under $HOME resolves into it, that each file holds the colour of
the slot its app uses, and that a tmux server and two Neovim instances started
before the switch show the new colours. On a host with Plasma whose desktop
session runs, it also checks that the session's KDE colour scheme moved to the
other of its A and B copies with the scheme's background, that the icons,
cursor, GTK theme and colour preference follow the scheme's dark or light
variant, that the look keeps its Plasma style, and that the Glass glow has the
scheme's blue. The expected colours come from the scheme's YAML in the pack.
It also checks that an unknown scheme exits 64 and changes nothing, that
`theme --reapply` finishes a switch interrupted after the stored scheme
changed, that it falls back to the record scheme when no scheme is stored,
that neither run changes the running session's KDE colour scheme, and that
the pack is a GC root. It prints a skip line for each scheme whose Plasma
checks cannot run.

It switches back to the scheme that was active, and exits 1 at the first
failed check, naming it.
EOF
  exit 64
}

host=
if [[ ${1:-} == --host ]]; then
  host=${2:-}
  [[ -n $host ]] || usage
  shift 2
fi
[[ $# -gt 0 ]] || usage
for slug in "$@"; do
  [[ $slug =~ ^[a-z0-9-]+$ ]] || usage
done

if [[ -n $host ]]; then
  remote=/tmp/check-theme-$$.sh
  scp -q "$0" "$host:$remote"
  exec ssh "$host" "bash $remote $* </dev/null; rc=\$?; rm -f $remote; exit \$rc"
fi

state=${XDG_STATE_HOME:-$HOME/.local/state}/oruc
pack=$state/theme/pack
scratch=$(mktemp -d)
tmux_socket=oruc-check-theme-$$
nvim_pids=()

fail() {
  echo "check-theme: $*" >&2
  exit 1
}

read -r original record < <(theme | sed -nE 's/^active: ([^ ]+) \(default: ([^)]+)\)$/\1 \2/p') || true
[[ -n ${original:-} && -n ${record:-} ]] || fail "theme printed no active and default scheme"

cleanup() {
  tmux -L "$tmux_socket" kill-server 2>/dev/null || true
  kill "${nvim_pids[@]}" 2>/dev/null || true
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
  local slug=$1 before=$2 previous=$3 now base variant bg icons cursor gtk style preference glow
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
  case $variant in
    light) icons=Papirus-Light cursor=Bibata-Modern-Classic gtk=adw-gtk3 ;;
    *) icons=Papirus-Dark cursor=Bibata-Modern-Ice gtk=adw-gtk3-dark ;;
  esac
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

points_at() {
  [[ $(readlink "$state/theme/current") == "pack/$1" ]] ||
    fail "$2: theme/current is $(readlink "$state/theme/current"), not pack/$1"
}

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
  if plasma_session "$slug"; then
    plasma_before=$(kdeglobal kdeglobals General ColorScheme)
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
  [[ -z $plasma_before ]] || check_plasma "$slug" "$plasma_before" "$previous"
  holds "$slug" .claude/themes/scheme.json "rgb($(decimal "$base00"))"
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

nix-store --gc --print-roots | grep -xF "\"$pack\" -> $(readlink "$pack")" >/dev/null || fail "$pack is not a GC root of the pack it links to"
echo "ok GC root"
