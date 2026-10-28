#!/usr/bin/env bash
set -euo pipefail

fail() {
  notify-send -u critical "Markdown Viewer" "$1" 2>/dev/null || true
  printf 'pandoc-md-viewer: %s\n' "$1" >&2
  exit 1
}

file="${1:-}"
[ -n "$file" ] || fail "No file given"
[ -f "$file" ] || fail "Not a file: $file"

theme_css="${XDG_CONFIG_HOME:-$HOME/.config}/oruc/pandoc-md-theme.css"
[ -f "$theme_css" ] || fail "Missing theme file: $theme_css"

name="$(basename -- "$file")"
dir="$(dirname -- "$file")"

find /tmp -maxdepth 1 -name 'pandoc-*.html' -mmin +60 -delete 2>/dev/null || true

out="$(mktemp --suffix=.html /tmp/pandoc-XXXXXX)" || fail "could not create temp file"

toc=()
if [ "$(grep -cE -e '^#{1,6}[[:space:]]' -- "$file" || true)" -ge 3 ]; then
  toc=(--toc --toc-depth=3)
fi

# Preprocess:
# 1) Drop a leading YAML frontmatter block (--- ... ---). Vault notes use
#    unquoted titles with colons, which pandoc's yaml_metadata_block rejects.
#    Without a closing fence the leading --- is a horizontal rule and stays.
# 2) Insert a blank line before a pipe table that directly follows a paragraph,
#    so pandoc sees a table without the gap (GitHub allows this). Fenced code
#    is left as it is.
# The reader also drops yaml_metadata_block, so a leftover or mid-file --- fence
# cannot stop the render.
# --highlight-style is the option pandoc 3.7 (nixpkgs) knows; pandoc 3.8 and later
# replaced it with --syntax-highlighting and deprecates the old name.
awk '
function emit(line) {
  if (match(line, /^[[:space:]]*(```|~~~)/)) {
    mark = substr(line, RSTART + RLENGTH - 3, 3)
    if (fence == "") fence = mark
    else if (mark == fence) fence = ""
  } else if (fence == "" && line ~ /^[[:space:]]*\|/ && prev !~ /^[[:space:]]*\|/ && prev ~ /[^[:space:]]/) {
    print ""
  }
  print line
  prev = line
}
NR == 1 && /^---[[:space:]]*$/ { fm = 1; n = 1; held[n] = $0; next }
fm == 1 {
  if (/^(---|\.\.\.)[[:space:]]*$/) { fm = 0; next }
  held[++n] = $0
  next
}
{ emit($0) }
END { if (fm == 1) for (i = 1; i <= n; i++) emit(held[i]) }
' "$file" |
  pandoc -s -f gfm-yaml_metadata_block+tex_math_dollars --embed-resources \
    "${toc[@]}" \
    --highlight-style="$PANDOC_MD_ASSETS/typewriter-neutral.theme" \
    --katex="$PANDOC_MD_KATEX" \
    --resource-path="$dir" \
    --metadata pagetitle="$name" \
    -c "$theme_css" \
    -c "$PANDOC_MD_ASSETS/pandoc-md.css" \
    -A "$PANDOC_MD_ASSETS/pandoc-md.afterbody.html" \
    -o "$out" || fail "pandoc failed on $name"

brave-origin "$out" || fail "could not open Brave"
