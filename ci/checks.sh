#!/usr/bin/env bash
# usage: ci/checks.sh
# The checks that the check job of .github/workflows/check.yml runs, in one
# place for each caller: that job, scripts/check-on-rog.sh and the updater
# (scripts/auto-update.sh). It stops at the first failure and names it.
# Evaluation warnings do not fail it; the summary at the end lists them.
set -euo pipefail
cd "$(dirname "$0")/.."

# CI forbids import from derivation, so every evaluation here does too.
nix_opts=(--option allow-import-from-derivation false)
log=$(mktemp)
trap 'rm -f -- "$log"' EXIT

# check NAME COMMAND...: runs one check under a heading. COMMAND runs with
# errexit off, so a function passed here returns its own failure.
check() {
  local name=$1
  shift
  echo "== $name"
  "$@" || {
    echo "The check \"$name\" failed." >&2
    # An annotation, so the failed check shows on the PR without the log.
    [[ ${GITHUB_ACTIONS:-} != true ]] || echo "::error::The check \"$name\" failed."
    exit 1
  }
}

lock_files() {
  local flake
  for flake in . ./kernel-cache; do
    nix flake metadata "${nix_opts[@]}" --no-update-lock-file "$flake" >/dev/null || {
      echo "flake.lock of $flake does not match its flake.nix, as after a new or changed input; Nix's error above names the cause, and scripts/check-on-rog.sh --fix relocks" >&2
      return 1
    }
  done
}

flake_outputs() {
  nix flake check "${nix_opts[@]}" --no-build --no-write-lock-file 2>&1 | tee "$log"
}

# No host turns features.boxBrowser on, so this evaluates the module on
# nixos-desktop with the feature forced on (ci/box-browser.nix).
box_browser() {
  local out
  out=$(nix eval "${nix_opts[@]}" --json --impure \
    --expr 'import ./ci/box-browser.nix (builtins.getFlake (toString ./.))') || return 1
  jq -e '.userUnits | contains(["box-browser", "box-display"])' <<<"$out" >/dev/null || {
    echo "The forced-on host lacks a box browser unit." >&2
    return 1
  }
  # Xvnc has no password, so its command line must keep it on localhost.
  jq -e '.displayCommand | contains(" -localhost ") and contains(" -SecurityTypes None")' \
    <<<"$out" >/dev/null || {
    echo "The box display no longer runs Xvnc as -localhost with -SecurityTypes None." >&2
    return 1
  }
}

# With --no-write-lock-file, nix flake check passes an input that flake.lock
# lacks and only warns, and the input then follows its upstream unpinned. nix
# fmt writes the lock file, so this check runs first.
check "lock files" lock_files
check formatting nix fmt "${nix_opts[@]}" -- --ci
check "flake outputs" flake_outputs
check "kernel-cache packages" nix eval "${nix_opts[@]}" --json --no-write-lock-file \
  ./kernel-cache#packages.x86_64-linux --apply 'builtins.mapAttrs (_: p: p.drvPath)'
echo
# Not a flake output, so nix flake check does not evaluate it.
check "cached host packages" nix eval "${nix_opts[@]}" --json --impure \
  --expr 'import ./ci/cached-packages.nix (builtins.getFlake (toString ./.))' \
  --apply 'builtins.mapAttrs (_: builtins.mapAttrs (_: p: p.drvPath))'
echo
check "box browser feature" box_browser
echo

warnings=$(grep -o 'evaluation warning: .*' "$log" | sort -u || true)
if [[ -z $warnings ]]; then
  echo "No evaluation warnings."
else
  printf '%d distinct evaluation warnings:\n%s\n' "$(wc -l <<<"$warnings")" "$warnings"
fi
