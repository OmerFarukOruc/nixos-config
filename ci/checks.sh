#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

nix_opts=(--option allow-import-from-derivation false)
log=$(mktemp)
trap 'rm -f -- "$log"' EXIT

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
      echo "flake.lock of $flake does not match its flake.nix, as after a new or changed input; Nix's error above names the cause, and scripts/check.sh --fix relocks" >&2
      return 1
    }
  done
}

flake_outputs() {
  nix eval "${nix_opts[@]}" --json --no-write-lock-file '.#.' --apply '
    outputs:
      builtins.attrNames outputs == [ "checks" "formatter" "nixosConfigurations" ]
      && builtins.attrNames outputs.formatter == [ "x86_64-linux" ]
      && builtins.isString outputs.formatter.x86_64-linux.name
      && !builtins.hasContext outputs.formatter.x86_64-linux.name
  ' | jq -e . >/dev/null || {
    echo "Extend ci/checks.sh coverage before changing output kinds or formatter systems; formatter names must be strings without context." >&2
    return 1
  }
}

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

box_browser() {
  local out
  out=$(nix eval "${nix_opts[@]}" --json --impure \
    --expr 'import ./ci/box-browser.nix (builtins.getFlake (toString ./.))') || return 1
  jq -e '.userUnits | contains(["box-browser", "box-display"])' <<<"$out" >/dev/null || {
    echo "The forced-on host lacks a box browser unit." >&2
    return 1
  }
  jq -e '.displayCommand | contains(" -localhost ") and contains(" -SecurityTypes None")' \
    <<<"$out" >/dev/null || {
    echo "The box display no longer runs Xvnc as -localhost with -SecurityTypes None." >&2
    return 1
  }
}

server_record() {
  local out
  out=$(nix eval "${nix_opts[@]}" --json --impure \
    --expr 'import ./ci/server.nix (builtins.getFlake (toString ./.))') || return 1
  jq -e '.workstation | to_entries | map(select(.value)) | map(.key) | . == []' <<<"$out" >/dev/null || {
    echo "The server record gets a workstation piece: $(jq -c '.workstation | with_entries(select(.value)) | keys' <<<"$out")" >&2
    return 1
  }
  jq -e '.access | .tailscale and .tailscaleSsh and .openssh and (.sshOpenFirewall | not)
    and .sshPorts == [2222] and .sshListenAddresses == [] and .sshAuthentication == "publickey"
    and .udpPorts == [.tailscalePort]' \
    <<<"$out" >/dev/null || {
    echo "The server record's access setup changed: $(jq -c .access <<<"$out")" >&2
    return 1
  }
  jq -e '.boot | .enable and .efiSupport and .biosSupport and .biosDevice == "/dev/vda"
    and (.canTouchEfiVariables | not) and .efiInstallAsRemovable and .additionalFiles == {}' \
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
  jq -e '.streamed | .accepted and .workstationAccepted
    and ([.workstation | to_entries[] | select(.value) | .key] | sort)
      == ["browserCertificates", "browserVariable", "desktopPackages", "fontconfig", "mimeApps", "xkbLayout"]
    and (.desktop | .xrdp and (.xserver | not) and (.screensaver | not) and .keyboardLayout == "tr")' \
    <<<"$out" >/dev/null || {
    echo "The server record with a streamed desktop changed: $(jq -c .streamed <<<"$out")" >&2
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

server_boot() {
  local out
  out=$(nix eval "${nix_opts[@]}" --json --no-write-lock-file .#checks.x86_64-linux \
    --apply 'checks: builtins.mapAttrs (_: test: test.drvPath) checks') || return 1
  jq -e 'keys | contains(["risoluto-dev-1-boot-bios", "risoluto-dev-1-desktop", "risoluto-dev-1-self-deploy", "risoluto-dev-1-units"])' <<<"$out" >/dev/null || {
    echo "The flake checks lack a boot or deploy test of risoluto-dev-1: $(jq -c keys <<<"$out")" >&2
    return 1
  }
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
check "server boot tests" server_boot
echo

warnings=$(grep -o 'evaluation warning: .*' "$log" | sort -u || true)
if [[ -z $warnings ]]; then
  echo "No evaluation warnings."
else
  printf '%d distinct evaluation warnings:\n%s\n' "$(wc -l <<<"$warnings")" "$warnings"
fi
