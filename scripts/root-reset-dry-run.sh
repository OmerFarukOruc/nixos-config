#!/usr/bin/env bash
# Lists what a root reset would drop: every file on the root subvolume outside
# the kept paths, /tmp, and the symlinks NixOS makes again at each boot. Run it
# as root on rog with a kept-paths file:
#
#   sudo scripts/root-reset-dry-run.sh /etc/oruc/kept-paths
#
# Output: bytes, files and directory, one line per directory, three levels
# deep (four under /var/lib and /var/cache).
set -euo pipefail

if [[ $# -ne 1 || ! -r $1 ]]; then
  echo "Usage: $0 KEPT_PATHS_FILE" >&2
  exit 64
fi

skip=(-path /tmp -prune)
while IFS= read -r path; do
  [[ -n $path ]] && skip+=(-o -path "$path" -prune)
done <"$1"

find / -xdev \( "${skip[@]}" \) \
  -o \( -type l \( -lname '/etc/static/*' -o -lname '/nix/store/*' \) \) \
  -o \( ! -type d -printf '%s\t%p\n' \) |
  awk -F'\t' '
    {
      n = split($2, part, "/")
      depth = ($2 ~ "^/var/(lib|cache)/") ? 4 : 3
      dir = ""
      for (i = 2; i <= n && i <= depth + 1; i++) dir = dir "/" part[i]
      bytes[dir] += $1
      files[dir]++
    }
    END { for (dir in bytes) printf "%d\t%d\t%s\n", bytes[dir], files[dir], dir }
  ' |
  sort -t $'\t' -k3
