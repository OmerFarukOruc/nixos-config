#!/usr/bin/env bash
# usage: ci/checks.sh
# The checks a change passes before it reaches main, in one place for each
# caller: the pre-push hook and devenv test (devenv.nix),
# scripts/check-on-rog.sh and .github/workflows/update.yml. It stops at the
# first failure and names it.
# Evaluation warnings do not fail it; the summary at the end lists them.
set -euo pipefail
cd "$(dirname "$0")/.."

# This repository forbids import from derivation (AGENTS.md, Nixpkgs), so every
# evaluation here does too.
nix_opts=(--option allow-import-from-derivation false)
log=$(mktemp)
trap 'rm -f -- "$log"' EXIT

# check NAME COMMAND...: runs one check under a heading. COMMAND runs with
# errexit off, so a function passed here returns its own failure.
check() {
  local name=$1
  shift
  echo "== $name"
  "$@" 2>&1 | tee -a "$log" || {
    echo "The check \"$name\" failed." >&2
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

# nix fmt checks the formatter, and host_systems checks the host derivations.
# Refuse outputs they do not cover. nix fmt accepts a formatter name with
# string context, but nix flake check does not.
flake_outputs() {
  nix eval "${nix_opts[@]}" --json --no-write-lock-file '.#.' --apply '
    outputs:
      builtins.attrNames outputs == [ "formatter" "nixosConfigurations" ]
      && builtins.attrNames outputs.formatter == [ "x86_64-linux" ]
      && builtins.isString outputs.formatter.x86_64-linux.name
      && !builtins.hasContext outputs.formatter.x86_64-linux.name
  ' | jq -e . >/dev/null || {
    echo "Extend ci/checks.sh coverage before changing output kinds or formatter systems; formatter names must be strings without context." >&2
    return 1
  }
}

# Force each drvPath as well as the derivation type: a package that throws can
# hide inside a toplevel that passes the type check. Separate evaluators release
# the heap between hosts.
host_systems() {
  local hosts host
  hosts=$(nix eval "${nix_opts[@]}" --json --no-write-lock-file .#nixosConfigurations \
    --apply builtins.attrNames | jq -r '.[]') || return 1
  [[ -n $hosts ]] || {
    echo "The flake defines no host." >&2
    return 1
  }
  for host in $hosts; do
    echo "$host"
    nix eval "${nix_opts[@]}" --raw --no-write-lock-file \
      ".#nixosConfigurations.$host.config.system.build.toplevel" --apply '
        toplevel:
          if builtins.isAttrs toplevel && (toplevel.type or null) == "derivation"
          then toplevel.drvPath
          else throw "The host toplevel must be a derivation."
      ' >/dev/null || return 1
  done
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

# Evaluates a server record with Limine's BIOS stage and no login sessions
# (ci/server.nix), whatever the hosts are, and the schema's rejections.
server_record() {
  local out
  out=$(nix eval "${nix_opts[@]}" --json --impure \
    --expr 'import ./ci/server.nix (builtins.getFlake (toString ./.))') || return 1
  jq -e '.workstation | to_entries | map(select(.value)) | map(.key) | . == []' <<<"$out" >/dev/null || {
    echo "The server record gets a workstation piece: $(jq -c '.workstation | with_entries(select(.value)) | keys' <<<"$out")" >&2
    return 1
  }
  jq -e '.access | .tailscale and .tailscaleSsh and .openssh and (.sshOpenFirewall | not)
    and .sshListenAddresses == ["127.0.0.1:22"] and .udpPorts == [.tailscalePort]' \
    <<<"$out" >/dev/null || {
    echo "The server record's access setup changed: $(jq -c .access <<<"$out")" >&2
    return 1
  }
  jq -e '.boot | .enable and .efiSupport and .biosSupport and .biosDevice == "/dev/vda"
    and (.canTouchEfiVariables | not) and .efiInstallAsRemovable and .extraInstallCommands == ""' \
    <<<"$out" >/dev/null || {
    echo "The server record's boot loader does not follow its record: $(jq -c .boot <<<"$out")" >&2
    return 1
  }
  jq -e '.limineHosts | (keys | contains(["nixos-desktop", "nixos-rog"]))
    and all(.[]; (.efiInstallAsRemovable | not) and .fallbackCopy)' \
    <<<"$out" >/dev/null || {
    echo "A Limine host lost the fallback copy of its EFI binary: $(jq -c .limineHosts <<<"$out")" >&2
    return 1
  }
  jq -e '.accepted' <<<"$out" >/dev/null || {
    echo "The schema rejects the server record itself, so the rejection checks below prove nothing." >&2
    return 1
  }
  jq -e '.rejected | to_entries | map(select(.value | not)) | map(.key) | . == []' <<<"$out" >/dev/null || {
    echo "The schema accepts what a server may not set: $(jq -c '.rejected | with_entries(select(.value | not)) | keys' <<<"$out")" >&2
    return 1
  }
}

# The image that scripts/boot-server-vm-on-rog.sh boots has to evaluate; its
# boot runs by hand, because it needs KVM and minutes.
server_vm() {
  nix eval "${nix_opts[@]}" --raw --impure \
    --expr '(import ./ci/server-vm.nix (builtins.getFlake (toString ./.))).image.drvPath' >/dev/null
}

# With --no-write-lock-file, evaluation accepts an input that flake.lock lacks
# and only warns, so the input follows its upstream unpinned. nix fmt writes
# the lock file, so the lock check runs first.
check "lock files" lock_files
check formatting nix fmt "${nix_opts[@]}" -- --ci
check "flake outputs" flake_outputs
check "host systems" host_systems
check "kernel-cache packages" nix eval "${nix_opts[@]}" --json --no-write-lock-file \
  ./kernel-cache#packages.x86_64-linux --apply 'builtins.mapAttrs (_: p: p.drvPath)'
echo
check "box browser feature" box_browser
echo
check "server record" server_record
echo
check "server boot test image" server_vm
echo

warnings=$(grep -o 'evaluation warning: .*' "$log" | sort -u || true)
if [[ -z $warnings ]]; then
  echo "No evaluation warnings."
else
  printf '%d distinct evaluation warnings:\n%s\n' "$(wc -l <<<"$warnings")" "$warnings"
fi
