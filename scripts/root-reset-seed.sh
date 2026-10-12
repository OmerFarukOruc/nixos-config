#!/usr/bin/env bash
# Creates @nixos-keep, the subvolume that machines/nixos-rog/root-reset.nix
# bind-mounts the kept paths from, copies each kept path it lacks from the
# live root with that system's oruc-keep-copy, and stores oruc's password hash
# there. Run it as root on rog with the system that boots next, right before
# that boot:
#
#   sudo scripts/root-reset-seed.sh /nix/var/nix/profiles/system
#
# The initrd resets the root only once this script has finished. After that,
# a switch copies newly kept paths by itself; a deploy with the boot action
# does not activate, so run this script again before its reboot.
set -euo pipefail

if [[ $# -ne 1 || ! -x $1/sw/bin/oruc-keep-copy ]]; then
  echo "Usage: $0 SYSTEM (a system built with root-reset.nix)" >&2
  exit 64
fi
system=$1

device=$(findmnt -n -o SOURCE --target / | sed 's/\[.*//')
top=$(mktemp -d)
mount -t btrfs -o subvolid=5 "$device" "$top"
trap 'umount "$top"; rmdir "$top"' EXIT
keep=$top/@nixos-keep

[[ -d $keep ]] || btrfs subvolume create "$keep"

"$system/sw/bin/oruc-keep-copy" "$keep" "$system/etc/oruc/kept-paths"

if [[ ! -e $keep/secrets/oruc-password ]]; then
  hash=$(awk -F: '$1 == "oruc" { print $2 }' /etc/shadow)
  if [[ $hash != '$'* ]]; then
    echo "oruc has no password hash in /etc/shadow." >&2
    exit 1
  fi
  install -d -m 0700 "$keep/secrets"
  (
    umask 077
    printf '%s\n' "$hash" >"$keep/secrets/oruc-password"
  )
  echo "copied  oruc's password hash"
fi

touch "$keep/.oruc-seeded"
