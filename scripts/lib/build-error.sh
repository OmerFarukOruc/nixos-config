# shellcheck shell=bash
# Sourced by scripts/prepare-update.sh.
# build_error LOG: prints the line of a failed nix build's stderr that names
# the cause, for a notification. That is the last line of the builder's log
# (Nix prefixes those with "> "), or the first "error:" line when the build
# never ran, such as for a failed download. Store hashes are shortened.
build_error() {
  local line
  line=$(sed -n 's/^[[:space:]]*> //p' "$1" | tail -n 1)
  [[ -n $line ]] || line=$(grep -m 1 '^error:' "$1" || true)
  line=$(sed -E 's|/nix/store/[a-z0-9]{32}-|/nix/store/…-|g' <<<"$line")
  printf '%s\n' "${line:0:200}"
}
