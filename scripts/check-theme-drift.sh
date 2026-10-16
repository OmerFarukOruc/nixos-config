#!/usr/bin/env bash
# Fails when a tracked file holds a fixed color, because a color must come from
# the scheme (config.scheme, or oruc.theme.ansi). A line is flagged when it has
#   - #RRGGBB or #RRGGBBAA (#000000 and #00000000 carry no hue and pass),
#   - rgb(, rgba(, hsl(, hsla(, oklch( or oklab( followed by a digit or a dot,
#   - #RGB or #RGBA, in *.css files only. Elsewhere a 3-digit anchor such as
#     #fix is not a color.
# A line that holds 'theme-drift-ok: <reason>' passes. A file that matches an
# entry of scripts/theme-drift-allow.txt ('path-or-glob<TAB>reason') passes, and
# an entry that matches no tracked file fails, so the list cannot go stale.
# Markdown, lock files and assets/ (scheme files, wallpapers) are not checked.
#
# usage: scripts/check-theme-drift.sh [FILE...]
# Paths are relative to the repository root. With no file it checks every
# tracked file; treefmt passes the changed files and always runs this from the
# root. Needs bash, git and GNU grep with -P.
set -euo pipefail
cd "$(dirname "$0")/.."

allow_file=scripts/theme-drift-allow.txt

hex='(?<![\w&])#(?!0{6}(?:0{2})?(?!\w))(?:[0-9A-Fa-f]{8}|[0-9A-Fa-f]{6})(?!\w)'
fn='\b(?:rgba?|hsla?|oklch|oklab)\(\s*[0-9.]'
short='(?<![\w&])#(?:[0-9A-Fa-f]{4}|[0-9A-Fa-f]{3})(?!\w)'

status=0
found=false
mapfile -t tracked < <(git ls-files)

globs=()
while IFS=$'\t' read -r glob reason; do
  [[ -z $glob || $glob == '#'* ]] && continue
  if [[ -z ${reason:-} ]]; then
    printf '%s: entry %q has no reason\n' "$allow_file" "$glob" >&2
    status=1
  fi
  matched=false
  # shellcheck disable=SC2053 # the entry is a glob on purpose
  for f in "${tracked[@]}"; do [[ $f == $glob ]] && matched=true && break; done
  if [[ $matched == false ]]; then
    printf '%s: entry %q matches no tracked file; delete it\n' "$allow_file" "$glob" >&2
    status=1
  fi
  globs+=("$glob")
done <"$allow_file"

if (($# == 0)); then
  files=("${tracked[@]}")
else
  files=("$@")
fi

for f in "${files[@]}"; do
  f=${f#./}
  case $f in
    *.md | *.lock | assets/* | "$allow_file") continue ;;
  esac
  allowed=false
  # shellcheck disable=SC2053 # the entry is a glob on purpose
  for glob in "${globs[@]}"; do [[ $f == $glob ]] && allowed=true && break; done
  [[ $allowed == true ]] && continue

  pat="$hex|$fn"
  [[ $f == *.css ]] && pat="$pat|$short"
  hits=$(grep -nIP -- "$pat" "$f" | grep -vP 'theme-drift-ok:\s*\S' || true)
  [[ -z $hits ]] && continue
  while IFS= read -r hit; do
    printf '%s:%s\n' "$f" "$hit" >&2
  done <<<"$hits"
  status=1
  found=true
done

if [[ $found == true ]]; then
  echo 'fixed color: take it from config.scheme, or add "theme-drift-ok: <reason>" to the line, or list the file in' "$allow_file" >&2
fi
exit "$status"
