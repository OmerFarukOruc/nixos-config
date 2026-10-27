#!/usr/bin/env bash
# usage: scripts/build.sh [ATTRIBUTE...]
# Builds each flake ATTRIBUTE in a copy of this checkout on this host
# (scripts/lib/work-copy.sh) and prints each output path. Each ATTRIBUTE is a
# flake attribute such as .#nixosConfigurations.nixos-rog.pkgs.deskflow; with
# none it builds .#nixosConfigurations.nixos-rog.config.system.build.toplevel,
# which compiles whatever the caches lack. The build creates no result link and
# activates nothing, and the outputs stay in this host's store until garbage
# collection. It stops at the first attribute that fails, with that build's
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
. scripts/lib/work-copy.sh
copy_open
copy_run "${attrs[@]}" <<'REMOTE'
set -e
cd "$1"
shift
for attr in "$@"; do
  nix build --no-link --print-out-paths --no-write-lock-file "$attr" </dev/null
done
REMOTE
