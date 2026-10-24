#!/usr/bin/env bash
# usage: scripts/build-on-rog.sh [ATTRIBUTE...]
# Builds each flake ATTRIBUTE in a copy of this checkout on nixos-rog
# (scripts/lib/rog-copy.sh) and prints each output path. Each ATTRIBUTE is a
# flake attribute such as .#nixosConfigurations.nixos-rog.pkgs.deskflow; with
# none it builds .#nixosConfigurations.nixos-rog.config.system.build.toplevel,
# which compiles whatever the caches lack. The build creates no result link and
# activates nothing, and the outputs stay in rog's store until garbage
# collection. While nixos-rog is offline, nixos-desktop builds them in its own
# store instead. It stops at the first attribute that fails, with that build's
# exit status.
set -euo pipefail
cd "$(dirname "$0")/.."

attrs=("$@")
if ((${#attrs[@]} == 0)); then
  attrs=(.#nixosConfigurations.nixos-rog.config.system.build.toplevel)
fi
for attr in "${attrs[@]}"; do
  if [[ $attr != *#* || $attr == -* ]]; then
    echo "usage: $0 [ATTRIBUTE...]" >&2
    echo "$0: '$attr' is not a flake attribute such as .#nixosConfigurations.nixos-rog.pkgs.deskflow" >&2
    exit 2
  fi
done

# shellcheck source=/dev/null
. scripts/lib/rog-copy.sh
rog_copy_open
rog_remote "${attrs[@]}" <<'REMOTE'
set -e
cd "$1"
shift
for attr in "$@"; do
  nix build --no-link --print-out-paths --no-write-lock-file "$attr" </dev/null
done
REMOTE
