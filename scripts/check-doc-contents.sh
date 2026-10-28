#!/usr/bin/env bash
# Fails when the first list of a Markdown file is a contents list of
# '- [Title](#anchor)' lines and that list has no entry for one of the file's
# '## ' headings. A file whose first list is anything else is skipped. An entry
# matches a heading by its anchor, the way GitHub derives it from the heading
# text: a repeated heading gets the suffix -1, -2 and so on, counted over
# headings of every level. The list must be
# flat; an indented entry ends it.
#
# usage: scripts/check-doc-contents.sh [FILE.md...]
# With no file it checks every tracked *.md file; treefmt passes the files.
set -euo pipefail
# A UTF-8 locale keeps non-ASCII letters in the anchor, as GitHub does; treefmt
# may run this under the C locale.
export LC_ALL=C.UTF-8

if (($# == 0)); then
  cd "$(dirname "$0")/.."
  mapfile -t files < <(git ls-files '*.md')
else
  files=("$@")
fi

anchor() {
  local text=${1,,}
  text=${text//[^[:alnum:] _-]/}
  printf '%s' "${text// /-}"
}

heading_re='^(#{1,6}) +(.+)$'
status=0
for file in "${files[@]}"; do
  anchors=' ' headings=() levels=() in_fence=false first_list=true in_contents=false
  while IFS= read -r line; do
    if [[ $line == '```'* || $line == '~~~'* ]]; then
      [[ $in_fence == true ]] && in_fence=false || in_fence=true
      continue
    fi
    [[ $in_fence == true ]] && continue
    if [[ $first_list == true ]]; then
      if [[ $line =~ ^-\ \[.+\]\(#([^\)]+)\)$ ]]; then
        in_contents=true
        anchors+="${BASH_REMATCH[1]} "
        continue
      elif [[ $in_contents == true ]]; then
        first_list=false
      elif [[ $line =~ ^([-*]|[0-9]+\.)\  ]]; then
        continue 2
      fi
    fi
    if [[ $line =~ $heading_re ]]; then
      heading=${BASH_REMATCH[2]}
      headings+=("${heading%"${heading##*[![:space:]]}"}")
      levels+=("${#BASH_REMATCH[1]}")
    fi
  done <"$file"

  [[ $in_contents == true ]] || continue
  declare -A seen=()
  for i in "${!headings[@]}"; do
    heading=${headings[i]}
    want=$(anchor "$heading")
    n=${seen[k$want]:-0}
    seen[k$want]=$((n + 1))
    ((n == 0)) || want=$want-$n
    ((levels[i] == 2)) || continue
    if [[ $anchors != *" $want "* ]]; then
      printf '%s: the contents list has no entry for the heading "## %s" (expected #%s)\n' \
        "$file" "$heading" "$want" >&2
      status=1
    fi
  done
done
exit "$status"
