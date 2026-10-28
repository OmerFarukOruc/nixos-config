# shellcheck shell=bash
build_error() {
  local line
  line=$(sed -n 's/^[[:space:]]*> //p' "$1" | tail -n 1)
  [[ -n $line ]] || line=$(grep -m 1 '^error:' "$1" || true)
  line=$(sed -E 's|/nix/store/[a-z0-9]{32}-|/nix/store/…-|g' <<<"$line")
  printf '%s\n' "${line:0:200}"
}
