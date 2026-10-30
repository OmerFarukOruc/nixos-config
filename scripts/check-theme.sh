#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: scripts/check-theme.sh [--host HOST] SCHEME...

Runs `theme SCHEME` for each SCHEME on this host, or on HOST over SSH, and
checks that theme/current points at the scheme in the theme pack, that every
colour file under $HOME resolves into it, that each file holds the colour of
the slot its app uses, and that a tmux server and two Neovim instances started
before the switch show the new colours. The expected colours come from the
scheme's YAML in the pack. It also checks that an
unknown scheme exits 64 and changes nothing, that `theme --reapply` finishes
a switch interrupted after the stored scheme changed, that it falls back to
the record scheme when no scheme is stored, and that the pack is a GC root.

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

for slug in "$@"; do
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
  holds "$slug" .claude/themes/scheme.json \
    "$(printf 'rgb(%d,%d,%d)' "0x${base00:0:2}" "0x${base00:2:2}" "0x${base00:4:2}")"
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

interrupted=$1
[[ $interrupted != "$last" ]] || interrupted=$record
[[ $interrupted != "$last" ]] || fail "give a second scheme, because $last is the record scheme"
printf '%s\n' "$interrupted" >"$state/scheme"
theme --reapply >/dev/null || fail "theme --reapply exited $?"
points_at "$interrupted" "theme --reapply after an interrupted switch"
echo "ok interrupted switch"

rm "$state/scheme"
theme --reapply >/dev/null || fail "theme --reapply exited $?"
points_at "$record" "theme --reapply without a stored scheme"
echo "ok record fallback"

nix-store --gc --print-roots | grep -xF "\"$pack\" -> $(readlink "$pack")" >/dev/null || fail "$pack is not a GC root of the pack it links to"
echo "ok GC root"
